// HeartTalk: safely reconcile an already-processing Cashfree Payouts V2 transfer.
// This function NEVER initiates or retries a transfer. It only GETs the existing transfer_id.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, x-client-info, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS"
};
const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" }
});
const enc = new TextEncoder();

function amountToPaise(value: unknown): number {
  const match = String(value ?? "").trim().match(/^(\d{1,12})(?:\.(\d{1,2}))?$/);
  if (!match) return NaN;
  return Number(match[1]) * 100 + Number((match[2] || "").padEnd(2, "0"));
}
async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", enc.encode(value));
  return Array.from(new Uint8Array(digest)).map(x => x.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);

  try {
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    if (!jwt) return reply({ error: "Authentication required" }, 401);

    const url = Deno.env.get("SUPABASE_URL");
    const anon = Deno.env.get("SUPABASE_ANON_KEY");
    const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const cfId = Deno.env.get("CASHFREE_PAYOUT_CLIENT_ID");
    const cfSecret = Deno.env.get("CASHFREE_PAYOUT_CLIENT_SECRET");
    const env = (Deno.env.get("CASHFREE_PAYOUT_ENV") || "sandbox").toLowerCase();

    if (!url || !anon || !service) return reply({ error: "Supabase function configuration is incomplete" }, 503);
    if (!cfId || !cfSecret) return reply({ error: "Cashfree Payouts credentials are not configured" }, 503);
    if (env !== "sandbox") return reply({ error: "Production payout reconciliation is disabled; sandbox only" }, 403);

    const auth = createClient(url, anon, {
      global: { headers: { Authorization: `Bearer ${jwt}` } },
      auth: { persistSession: false, autoRefreshToken: false }
    });
    const { data: userData, error: userError } = await auth.auth.getUser(jwt);
    if (userError || !userData.user) return reply({ error: "Session expired" }, 401);
    const { data: allowed, error: permissionError } = await auth.rpc(
      "has_hearttalk_admin_permission",
      { p_permission: "withdrawals.manage" }
    );
    if (permissionError || allowed !== true) return reply({ error: "Withdrawal management permission required" }, 403);

    const body = await req.json().catch(() => ({}));
    const requestId = String(body.request_id || "");
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(requestId)) {
      return reply({ error: "Invalid payout request id" }, 400);
    }

    const db = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });
    const { data: payout, error: readError } = await db
      .from("hearttalk_cashfree_payout_requests")
      .select("id,host_id,amount_paise,status,cashfree_reference_id,cashfree_transfer_id,cashfree_initiation_http_status")
      .eq("id", requestId)
      .maybeSingle();
    if (readError || !payout) return reply({ error: "Payout request not found" }, 404);
    if (payout.status !== "processing") {
      return reply({ status: payout.status, message: "Only processing requests can be reconciled. No transfer was initiated." }, 409);
    }

    const expectedTransferId = "HTP_" + payout.id.replace(/-/g, "").slice(0, 32);
    const transferId = String(payout.cashfree_reference_id || "");
    if (transferId !== expectedTransferId || !/^HTP_[a-f0-9]{32}$/i.test(transferId)) {
      return reply({ error: "Stored Cashfree transfer ID does not match the payout request. Manual review required." }, 409);
    }

    let response: Response;
    try {
      response = await fetch(
        "https://sandbox.cashfree.com/payout/transfers?transfer_id=" + encodeURIComponent(transferId),
        {
          method: "GET",
          headers: {
            "Accept": "application/json",
            "x-api-version": "2024-01-01",
            "x-client-id": cfId,
            "x-client-secret": cfSecret
          }
        }
      );
    } catch (error) {
      console.error("Cashfree payout status lookup network error", error);
      await db.from("hearttalk_cashfree_payout_requests")
        .update({ cashfree_last_checked_at: new Date().toISOString(), updated_at: new Date().toISOString() })
        .eq("id", requestId).eq("status", "processing");
      return reply({
        status: "processing",
        transfer_id: transferId,
        message: "Cashfree status lookup was inconclusive. Reserved earnings remain locked; no retry was attempted."
      }, 202);
    }

    const provider = await response.json().catch(() => ({}));
    const checkedAt = new Date().toISOString();

    if (response.status === 404) {
      const initialHttp = Number(payout.cashfree_initiation_http_status);
      const definitive4xx = Number.isInteger(initialHttp)
        && initialHttp >= 400 && initialHttp < 500
        && ![408, 409, 425, 429].includes(initialHttp)
        && !payout.cashfree_transfer_id;

      if (definitive4xx) {
        const eventHash = await sha256Hex([
          "HEARTTALK_CASHFREE_NOT_ACCEPTED",
          payout.id,
          transferId,
          String(initialHttp),
          "404"
        ].join("|"));
        const { data: recovery, error: recoveryError } = await db.rpc(
          "hearttalk_fail_cashfree_payout_unaccepted",
          {
            p_request_id: payout.id,
            p_transfer_id: transferId,
            p_http_status: initialHttp,
            p_lookup_status: 404,
            p_event_hash: eventHash,
            p_admin_user_id: userData.user.id,
            p_failure_reason: "Cashfree definitively rejected initiation (HTTP " + initialHttp + ") and the same transfer ID was not found on status lookup."
          }
        );
        if (recoveryError) {
          console.error("Cashfree safe rejection recovery failed", recoveryError);
          return reply({ error: "Verified non-acceptance recovery failed; reserved earnings remain unchanged pending review." }, 500);
        }
        return reply({
          status: "failed",
          transfer_id: transferId,
          recovery,
          message: "Cashfree did not accept this transfer and status lookup confirmed it was not created. Reserved earnings were released."
        });
      }

      await db.from("hearttalk_cashfree_payout_requests")
        .update({
          cashfree_status: "NOT_FOUND_REQUIRES_REVIEW",
          cashfree_last_checked_at: checkedAt,
          updated_at: checkedAt
        })
        .eq("id", requestId).eq("status", "processing");
      return reply({
        status: "processing",
        transfer_id: transferId,
        message: "Cashfree does not show this transfer yet. This alone is not enough to release or retry; reserved earnings remain locked."
      }, 202);
    }

    if (!response.ok) {
      await db.from("hearttalk_cashfree_payout_requests")
        .update({ cashfree_last_checked_at: checkedAt, updated_at: checkedAt })
        .eq("id", requestId).eq("status", "processing");
      return reply({
        status: "processing",
        transfer_id: transferId,
        lookup_http_status: response.status,
        message: "Cashfree status lookup was inconclusive. Reserved earnings remain locked; no retry was attempted."
      }, 202);
    }

    const transfer = provider?.data && typeof provider.data === "object"
      ? (Array.isArray(provider.data) ? provider.data[0] : provider.data)
      : provider;
    const verifiedTransferId = String(transfer?.transfer_id || "");
    const providerStatus = String(transfer?.status || "").toUpperCase();
    const amountPaise = amountToPaise(transfer?.transfer_amount);
    const cfTransferId = transfer?.cf_transfer_id ? String(transfer.cf_transfer_id) : null;
    const knownStatuses = ["SUCCESS", "FAILED", "REVERSED", "REJECTED", "CANCELLED", "RECEIVED", "PENDING", "QUEUED", "PROCESSING"];

    if (verifiedTransferId !== transferId) return reply({ error: "Cashfree transfer ID mismatch; no database state changed." }, 409);
    if (!Number.isSafeInteger(amountPaise) || amountPaise !== Number(payout.amount_paise)) {
      return reply({ error: "Cashfree transfer amount mismatch; reserved earnings remain locked for manual review." }, 409);
    }
    if (transfer?.transfer_currency && String(transfer.transfer_currency).toUpperCase() !== "INR") {
      return reply({ error: "Cashfree transfer currency mismatch; reserved earnings remain locked." }, 409);
    }
    if (payout.cashfree_transfer_id && cfTransferId && payout.cashfree_transfer_id !== cfTransferId) {
      return reply({ error: "Cashfree provider reference mismatch; no database state changed." }, 409);
    }
    if (!knownStatuses.includes(providerStatus)) {
      return reply({ error: "Unrecognized Cashfree transfer status; reserved earnings remain locked." }, 502);
    }

    await db.from("hearttalk_cashfree_payout_requests")
      .update({ cashfree_last_checked_at: checkedAt, updated_at: checkedAt })
      .eq("id", requestId).eq("status", "processing");

    const statusCode = transfer?.status_code != null ? String(transfer.status_code) : null;
    const utr = transfer?.transfer_utr ? String(transfer.transfer_utr) : null;
    const failureReason = String(transfer?.status_description || transfer?.failure_reason || transfer?.message || "").slice(0, 500);
    const eventHash = await sha256Hex([
      "HEARTTALK_CASHFREE_ADMIN_RECONCILIATION",
      payout.id,
      transferId,
      cfTransferId || "",
      providerStatus,
      statusCode || "",
      String(amountPaise),
      utr || ""
    ].join("|"));

    const { data: result, error: applyError } = await db.rpc("hearttalk_apply_cashfree_payout_status", {
      p_event_hash: eventHash,
      p_transfer_id: transferId,
      p_cf_transfer_id: cfTransferId,
      p_provider_status: providerStatus,
      p_status_code: statusCode,
      p_amount_paise: amountPaise,
      p_utr: utr,
      p_failure_reason: failureReason || null,
      p_event_type: "ADMIN_RECONCILIATION",
      p_event_time: null
    });
    if (applyError) {
      console.error("Cashfree verified status could not be applied", applyError);
      return reply({ error: "Cashfree status was verified but could not be stored. No new transfer was initiated." }, 500);
    }

    return reply({
      status: result?.current_status || result?.status || "verified",
      transfer_id: transferId,
      cf_transfer_id: cfTransferId,
      cashfree_status: providerStatus,
      result,
      message: "Existing Cashfree transfer status was verified. No new transfer was initiated."
    });
  } catch (error) {
    console.error("reconcile-cashfree-host-payout:", error);
    return reply({ error: "Unable to reconcile Cashfree payout" }, 500);
  }
});