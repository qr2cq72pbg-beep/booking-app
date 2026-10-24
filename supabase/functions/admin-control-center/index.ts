// XBOOK Admin Control Center — privileged API.
// Auth: valid user JWT AND active platform_admins row.
// Reads: overview, businesses, customers.
// Writes: manual subscriptions via atomic RPCs only.
// service_role is used only inside this function. Never returned to the client.
import {
  asTrimmed,
  corsHeadersFor,
  identityKind,
  isMissingColumnError,
  isMissingRelationError,
  jsonResponse,
  ownerDisplayName,
  requirePlatformAdmin,
  UUID_RE,
  writeAdminAudit,
  type AdminClient,
} from "../_shared/admin-guard.ts";
import {
  asRpcObject,
  emailsForUsers,
  isComplimentaryOperation,
  isMissingFunctionError,
  isPaidOperation,
  loadCurrentSubscriptions,
  loadPackageCatalog,
  loadSubscriptionHistory,
  mapHistoryRow,
  mapSubscriptionRecord,
  parseDateOnly,
  rpcErrorMessage,
  rpcErrorStatus,
  SUBSCRIPTION_OPERATIONS,
  summarizeSubscriptions,
  utcToday,
  type SubscriptionOperation,
} from "../_shared/admin-subscriptions.ts";

type JsonMap = Record<string, unknown>;

const BUSINESS_SELECT_FULL =
  "business_id, business_slug, business_name, business_description, public_tagline, business_category, business_logo_url, business_cover_url, business_address, business_phone, business_email, business_website, onboarding_completed_at, onboarding_step";

const BUSINESS_SELECT_CORE =
  "business_id, business_slug, business_name, business_description, business_category, business_logo_url, business_cover_url, business_address, business_phone, onboarding_completed_at, onboarding_step";

const PROFILE_SELECT_FULL =
  "id, email, full_name, first_name, last_name, phone, created_at";

const PROFILE_SELECT_CORE = "id, email, full_name, phone, created_at";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeadersFor(req) });
  }
  if (req.method !== "POST") {
    return jsonResponse(req, { ok: false, error: "method_not_allowed" }, 405);
  }

  const gated = await requirePlatformAdmin(req);
  if (!gated.ok) return gated.response;

  let body: JsonMap = {};
  try {
    const parsed = await req.json();
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      body = parsed as JsonMap;
    }
  } catch {
    body = {};
  }

  const action = asTrimmed(body.action).toLowerCase();
  const { admin, userId } = gated.ctx;

  try {
    if (action === "session") {
      const payload = {
        ok: true as const,
        admin: {
          user_id: gated.ctx.userId,
          email: gated.ctx.email,
        },
      };
      await writeAdminAudit(admin, {
        actorUserId: userId,
        action: "session",
      });
      return jsonResponse(req, payload);
    }

    if (action === "overview") {
      const overview = await loadOverview(admin);
      await writeAdminAudit(admin, {
        actorUserId: userId,
        action: "overview",
        metadata: { businesses: overview.total_businesses },
      });
      return jsonResponse(req, { ok: true, overview });
    }

    if (action === "list_businesses") {
      const q = asTrimmed(body.q);
      const businesses = await loadBusinessList(admin, q);
      await writeAdminAudit(admin, {
        actorUserId: userId,
        action: "list_businesses",
        metadata: { q: q ? "[set]" : "", count: businesses.length },
      });
      return jsonResponse(req, { ok: true, businesses });
    }

    if (action === "get_business") {
      const businessId = asTrimmed(body.business_id);
      if (!UUID_RE.test(businessId)) {
        return jsonResponse(req, { ok: false, error: "invalid_business_id" }, 400);
      }
      const detail = await loadBusinessDetail(admin, businessId);
      if (!detail) {
        return jsonResponse(req, { ok: false, error: "not_found" }, 404);
      }
      await writeAdminAudit(admin, {
        actorUserId: userId,
        action: "get_business",
        businessId,
      });
      return jsonResponse(req, { ok: true, business: detail });
    }

    if (action === "list_business_customers") {
      const businessId = asTrimmed(body.business_id);
      if (!UUID_RE.test(businessId)) {
        return jsonResponse(req, { ok: false, error: "invalid_business_id" }, 400);
      }
      const exists = await businessExists(admin, businessId);
      if (!exists) {
        return jsonResponse(req, { ok: false, error: "not_found" }, 404);
      }
      const q = asTrimmed(body.q);
      const customers = await loadBusinessCustomers(admin, businessId, q);
      await writeAdminAudit(admin, {
        actorUserId: userId,
        action: "list_business_customers",
        businessId,
        metadata: { count: customers.length },
      });
      return jsonResponse(req, { ok: true, customers });
    }

    if (action === "list_subscriptions") {
      const workspace = await loadSubscriptionWorkspace(admin);
      if (!workspace) {
        return schemaNotReady(req);
      }
      await writeAdminAudit(admin, {
        actorUserId: userId,
        action: "list_subscriptions",
        metadata: { count: workspace.subscriptions.length },
      });
      return jsonResponse(req, { ok: true, ...workspace });
    }

    if (action === "list_subscription_history") {
      const businessId = asTrimmed(body.business_id);
      if (!UUID_RE.test(businessId)) {
        return jsonResponse(req, { ok: false, error: "invalid_business_id" }, 400);
      }
      const exists = await businessExists(admin, businessId);
      if (!exists) {
        return jsonResponse(req, { ok: false, error: "not_found" }, 404);
      }
      const history = await loadHistoryForBusiness(admin, businessId);
      if (history === "missing") {
        return schemaNotReady(req);
      }
      await writeAdminAudit(admin, {
        actorUserId: userId,
        action: "list_subscription_history",
        businessId,
        metadata: { count: history.length },
      });
      return jsonResponse(req, { ok: true, history });
    }

    if (action === "preview_subscription" || action === "apply_subscription") {
      const parsed = parseSubscriptionWrite(body);
      if ("error" in parsed) {
        return jsonResponse(req, {
          ok: false,
          error: parsed.error,
          message: rpcErrorMessage(parsed.error),
        }, rpcErrorStatus(parsed.error));
      }
      if (action === "apply_subscription" && !parsed.idempotencyKey) {
        return jsonResponse(req, {
          ok: false,
          error: "invalid_idempotency_key",
          message: rpcErrorMessage("invalid_idempotency_key"),
        }, 400);
      }
      const exists = await businessExists(admin, parsed.businessId);
      if (!exists) {
        return jsonResponse(req, { ok: false, error: "not_found" }, 404);
      }

      if (action === "preview_subscription") {
        const previewArgs: Record<string, unknown> = {
          p_business_id: parsed.businessId,
          p_package_id: parsed.packageId,
          p_operation: parsed.operation,
          p_starts_on: parsed.startsOn,
        };
        if (isComplimentaryOperation(parsed.operation)) {
          previewArgs.p_expires_on = parsed.expiresOn;
        }
        const preview = await callSubscriptionRpc(admin, "admin_preview_business_subscription", previewArgs);
        if (!preview.ok) {
          return jsonResponse(req, {
            ok: false,
            error: preview.error,
            message: rpcErrorMessage(preview.error),
          }, rpcErrorStatus(preview.error));
        }
        const previewPayload = { ...preview.data };
        const catalog = await loadPackageCatalog(admin);
        if (catalog !== "missing") {
          const selected = catalog.all.find((pkg) => pkg.package_id === parsed.packageId);
          if (selected) {
            previewPayload.package = selected;
          }
        }
        await writeAdminAudit(admin, {
          actorUserId: userId,
          action: "preview_subscription",
          businessId: parsed.businessId,
          metadata: {
          operation: parsed.operation,
          package_id: parsed.packageId,
          expires_on: parsed.expiresOn,
        },
        });
        return jsonResponse(req, { ok: true, preview: previewPayload });
      }

      const applyArgs: Record<string, unknown> = {
        p_business_id: parsed.businessId,
        p_package_id: parsed.packageId,
        p_operation: parsed.operation,
        p_starts_on: parsed.startsOn,
        p_idempotency_key: parsed.idempotencyKey,
        p_actor_user_id: userId,
        p_note: parsed.note,
      };
      if (isComplimentaryOperation(parsed.operation)) {
        applyArgs.p_expires_on = parsed.expiresOn;
      }
      const applied = await callSubscriptionRpc(admin, "admin_apply_business_subscription", applyArgs);
      if (!applied.ok) {
        return jsonResponse(req, {
          ok: false,
          error: applied.error,
          message: rpcErrorMessage(applied.error),
        }, rpcErrorStatus(applied.error));
      }
      await writeAdminAudit(admin, {
        actorUserId: userId,
        action: "apply_subscription",
        businessId: parsed.businessId,
        metadata: {
          operation: parsed.operation,
          package_id: parsed.packageId,
          expires_on: parsed.expiresOn,
          history_id: applied.data.history_id ?? null,
          replayed: applied.data.replayed === true,
        },
      });
      return jsonResponse(req, { ok: true, result: applied.data });
    }

    return jsonResponse(req, { ok: false, error: "invalid_action" }, 400);
  } catch (err) {
    const message = err instanceof Error ? err.message : "internal_error";
    if (message === "not_configured") {
      return jsonResponse(req, {
        ok: false,
        error: "not_configured",
        message: "Required Control Center tables are not applied yet.",
      }, 503);
    }
    return jsonResponse(req, { ok: false, error: "internal_error" }, 500);
  }
});

async function selectBusinesses(admin: AdminClient): Promise<JsonMap[]> {
  const full = await admin.from("business_settings").select(BUSINESS_SELECT_FULL);
  if (!full.error) return Array.isArray(full.data) ? full.data as JsonMap[] : [];
  if (isMissingRelationError(full.error)) throw new Error("not_configured");
  if (isMissingColumnError(full.error)) {
    const core = await admin.from("business_settings").select(BUSINESS_SELECT_CORE);
    if (core.error) throw new Error("query_failed");
    return Array.isArray(core.data) ? core.data as JsonMap[] : [];
  }
  throw new Error("query_failed");
}

async function selectProfiles(admin: AdminClient, ids: string[]): Promise<JsonMap[]> {
  if (!ids.length) return [];
  const full = await admin.from("user_profiles").select(PROFILE_SELECT_FULL).in("id", ids);
  if (!full.error) return Array.isArray(full.data) ? full.data as JsonMap[] : [];
  if (isMissingColumnError(full.error)) {
    const core = await admin.from("user_profiles").select(PROFILE_SELECT_CORE).in("id", ids);
    if (core.error) return [];
    return Array.isArray(core.data) ? core.data as JsonMap[] : [];
  }
  return [];
}

async function customerCountsByBusiness(
  admin: AdminClient,
): Promise<Map<string, { crm_records: number; linked_members: number; guest_records: number }>> {
  const map = new Map<string, { crm_records: number; linked_members: number; guest_records: number }>();
  const { data, error } = await admin
    .from("business_customers")
    .select("business_id, customer_user_id");
  if (error) {
    if (isMissingRelationError(error)) return map;
    throw new Error("query_failed");
  }
  for (const row of Array.isArray(data) ? data : []) {
    const businessId = asTrimmed((row as JsonMap).business_id);
    if (!businessId) continue;
    const current = map.get(businessId) || {
      crm_records: 0,
      linked_members: 0,
      guest_records: 0,
    };
    current.crm_records += 1;
    if (asTrimmed((row as JsonMap).customer_user_id)) {
      current.linked_members += 1;
    } else {
      current.guest_records += 1;
    }
    map.set(businessId, current);
  }
  return map;
}

async function countExact(
  admin: AdminClient,
  table: string,
  match?: Record<string, string>,
): Promise<number | null> {
  let query = admin.from(table).select("*", { count: "exact", head: true });
  if (match) {
    for (const [key, value] of Object.entries(match)) {
      query = query.eq(key, value);
    }
  }
  const { count, error } = await query;
  if (error) return null;
  return typeof count === "number" ? count : 0;
}

async function loadOverview(admin: AdminClient) {
  const [
    totalBusinesses,
    registeredCustomers,
    crmRows,
    bookings,
  ] = await Promise.all([
    countExact(admin, "business_settings"),
    countExact(admin, "user_profiles", { role: "customer" }),
    admin.from("business_customers").select("customer_user_id"),
    countExact(admin, "bookings"),
  ]);

  if (crmRows.error && !isMissingRelationError(crmRows.error)) {
    throw new Error("query_failed");
  }

  const crmList = Array.isArray(crmRows.data) ? crmRows.data : [];
  const linkedIds = new Set<string>();
  let memberships = 0;
  let guestRecords = 0;
  for (const row of crmList) {
    const uid = asTrimmed((row as JsonMap).customer_user_id);
    if (uid) {
      memberships += 1;
      linkedIds.add(uid);
    } else {
      guestRecords += 1;
    }
  }

  const subscriptionSummary = await loadOverviewSubscriptions(admin, totalBusinesses ?? 0);

  return {
    total_businesses: totalBusinesses ?? 0,
    total_business_owners: totalBusinesses ?? 0,
    unique_registered_customers: registeredCustomers ?? 0,
    unique_customers_linked_to_businesses: linkedIds.size,
    customer_memberships: memberships,
    crm_customer_records: crmList.length,
    guest_crm_records: guestRecords,
    total_bookings: bookings,
    bookings_available: bookings !== null,
    subscriptions_available: subscriptionSummary.available,
    active_subscriptions: subscriptionSummary.active,
    expired_subscriptions: subscriptionSummary.expired,
    complimentary_subscriptions: subscriptionSummary.complimentary,
    paid_active_subscriptions: subscriptionSummary.paid_active,
    unconfigured_subscriptions: subscriptionSummary.unconfigured,
    definitions: {
      total_businesses: "Rows in business_settings. One business per owner account.",
      total_business_owners:
        "Same as total businesses (business_id = owner auth user id). staff_members are not owners.",
      unique_registered_customers:
        "user_profiles rows with role = customer. Includes customers who never joined a business.",
      unique_customers_linked_to_businesses:
        "Distinct business_customers.customer_user_id values. One person at many businesses counts once.",
      customer_memberships:
        "business_customers rows with customer_user_id set. One person at many businesses counts many times.",
      crm_customer_records:
        "All business_customers rows, including unlinked guest/manual CRM identities.",
      guest_crm_records:
        "business_customers rows with no linked auth user.",
      total_bookings: "Count of bookings rows when the table is readable.",
      active_subscriptions:
        "Entitlement rows that are active: paid with expires_on today or later, complimentary with a future date or no expiration, or trial with expires_at in the future. Not enforced on bookings.",
      complimentary_subscriptions:
        "Active complimentary (FREE) rows. Not paid revenue.",
      paid_active_subscriptions:
        "Active FLEX / PLUS / MAX rows only. These are the only revenue entitlements.",
      expired_subscriptions:
        "Paid/FREE rows whose expires_on is before today, or trial rows whose expires_at has passed. Unlimited complimentary is never expired.",
      unconfigured_subscriptions:
        "Businesses with no entitlement row. Grandfathered: unconfigured is not expired.",
    },
  };
}

function matchesQuery(q: string, parts: Array<string | null | undefined>): boolean {
  if (!q) return true;
  const needle = q.toLowerCase();
  return parts.some((part) => asTrimmed(part).toLowerCase().includes(needle));
}

function mapOwner(profile: JsonMap | undefined, businessId: string) {
  if (!profile) {
    return {
      user_id: businessId,
      display_name: null,
      email: null,
      phone: null,
      registered_at: null,
      profile_present: false,
    };
  }
  return {
    user_id: businessId,
    display_name: ownerDisplayName(profile),
    email: asTrimmed(profile.email) || null,
    phone: asTrimmed(profile.phone) || null,
    registered_at: profile.created_at ? String(profile.created_at) : null,
    profile_present: true,
  };
}

function mapBusiness(row: JsonMap) {
  return {
    business_id: asTrimmed(row.business_id),
    business_slug: asTrimmed(row.business_slug) || null,
    business_name: asTrimmed(row.business_name) || "Untitled business",
    business_description: asTrimmed(row.business_description) || null,
    public_tagline: asTrimmed(row.public_tagline) || null,
    business_category: asTrimmed(row.business_category) || null,
    business_logo_url: asTrimmed(row.business_logo_url) || null,
    business_cover_url: asTrimmed(row.business_cover_url) || null,
    business_address: asTrimmed(row.business_address) || null,
    business_phone: asTrimmed(row.business_phone) || null,
    business_email: asTrimmed(row.business_email) || null,
    business_website: asTrimmed(row.business_website) || null,
    onboarding_completed_at: row.onboarding_completed_at
      ? String(row.onboarding_completed_at)
      : null,
    onboarding_step: typeof row.onboarding_step === "number" ? row.onboarding_step : null,
  };
}

async function loadBusinessList(admin: AdminClient, q: string) {
  const [rows, counts] = await Promise.all([
    selectBusinesses(admin),
    customerCountsByBusiness(admin),
  ]);
  const ids = rows.map((row) => asTrimmed(row.business_id)).filter(Boolean);
  const profiles = await selectProfiles(admin, ids);
  const profileById = new Map(profiles.map((p) => [asTrimmed(p.id), p]));

  const list = rows.map((row) => {
    const businessId = asTrimmed(row.business_id);
    const owner = mapOwner(profileById.get(businessId), businessId);
    const tally = counts.get(businessId) || {
      crm_records: 0,
      linked_members: 0,
      guest_records: 0,
    };
    return {
      ...mapBusiness(row),
      owner,
      customer_counts: tally,
    };
  }).filter((row) =>
    matchesQuery(q, [
      row.business_name,
      row.business_slug,
      row.business_category,
      row.business_email,
      row.owner.display_name,
      row.owner.email,
      row.business_id,
    ])
  );

  list.sort((a, b) => a.business_name.localeCompare(b.business_name));
  return list;
}

async function businessExists(admin: AdminClient, businessId: string): Promise<boolean> {
  const { data, error } = await admin
    .from("business_settings")
    .select("business_id")
    .eq("business_id", businessId)
    .maybeSingle();
  if (error) return false;
  return Boolean(data);
}

async function selectBusinessById(
  admin: AdminClient,
  businessId: string,
): Promise<JsonMap | null> {
  const full = await admin
    .from("business_settings")
    .select(BUSINESS_SELECT_FULL)
    .eq("business_id", businessId)
    .maybeSingle();
  if (!full.error) return (full.data as JsonMap | null) ?? null;
  if (isMissingRelationError(full.error)) throw new Error("not_configured");
  if (isMissingColumnError(full.error)) {
    const core = await admin
      .from("business_settings")
      .select(BUSINESS_SELECT_CORE)
      .eq("business_id", businessId)
      .maybeSingle();
    if (core.error) throw new Error("query_failed");
    return (core.data as JsonMap | null) ?? null;
  }
  throw new Error("query_failed");
}

async function customerCountsForBusiness(
  admin: AdminClient,
  businessId: string,
): Promise<{ crm_records: number; linked_members: number; guest_records: number }> {
  const { data, error } = await admin
    .from("business_customers")
    .select("customer_user_id")
    .eq("business_id", businessId);
  if (error) {
    if (isMissingRelationError(error)) {
      return { crm_records: 0, linked_members: 0, guest_records: 0 };
    }
    throw new Error("query_failed");
  }
  let linked_members = 0;
  let guest_records = 0;
  const rows = Array.isArray(data) ? data : [];
  for (const row of rows) {
    if (asTrimmed((row as JsonMap).customer_user_id)) linked_members += 1;
    else guest_records += 1;
  }
  return { crm_records: rows.length, linked_members, guest_records };
}

async function loadBusinessDetail(admin: AdminClient, businessId: string) {
  const row = await selectBusinessById(admin, businessId);
  if (!row) return null;

  const [profiles, tally, bookingCount, subscription] = await Promise.all([
    selectProfiles(admin, [businessId]),
    customerCountsForBusiness(admin, businessId),
    countExact(admin, "bookings", { business_id: businessId }),
    loadSubscriptionForBusiness(admin, {
      business_id: asTrimmed(row.business_id),
      business_name: asTrimmed(row.business_name) || "Untitled business",
      business_slug: asTrimmed(row.business_slug) || null,
    }),
  ]);

  return {
    ...mapBusiness(row),
    owner: mapOwner(profiles[0], businessId),
    customer_counts: tally,
    booking_count: bookingCount,
    bookings_available: bookingCount !== null,
    subscription: subscription === "missing" ? null : subscription,
    subscriptions_available: subscription !== "missing",
  };
}

async function loadBusinessCustomers(
  admin: AdminClient,
  businessId: string,
  q: string,
) {
  const { data, error } = await admin
    .from("business_customers")
    .select(
      "id, business_id, client_key, customer_number, display_name, phone, email, first_seen_at, created_at, customer_user_id, approval_status",
    )
    .eq("business_id", businessId)
    .order("customer_number", { ascending: true })
    .limit(500);

  if (error) {
    if (isMissingRelationError(error)) return [];
    throw new Error("query_failed");
  }

  const rows = Array.isArray(data) ? data as JsonMap[] : [];
  const linkedIds = [
    ...new Set(
      rows.map((row) => asTrimmed(row.customer_user_id)).filter(Boolean),
    ),
  ];
  const profiles = await selectProfiles(admin, linkedIds);
  const profileById = new Map(profiles.map((p) => [asTrimmed(p.id), p]));

  const mapped = rows.map((row) => {
    const customerUserId = asTrimmed(row.customer_user_id) || null;
    const profile = customerUserId ? profileById.get(customerUserId) : undefined;
    const clientKey = asTrimmed(row.client_key);
    const kind = identityKind(clientKey, customerUserId);
    return {
      id: asTrimmed(row.id),
      customer_number: typeof row.customer_number === "number" ? row.customer_number : null,
      display_name: asTrimmed(row.display_name) || asTrimmed(profile?.full_name) || null,
      phone: asTrimmed(row.phone) || asTrimmed(profile?.phone) || null,
      email: asTrimmed(row.email) || asTrimmed(profile?.email) || null,
      approval_status: asTrimmed(row.approval_status) || "approved",
      first_seen_at: row.first_seen_at ? String(row.first_seen_at) : null,
      identity_kind: kind,
      is_registered_user: Boolean(customerUserId),
      is_guest_crm: !customerUserId,
      customer_user_id: customerUserId,
    };
  }).filter((row) =>
    matchesQuery(q, [
      row.display_name,
      row.email,
      row.phone,
      row.customer_number != null ? String(row.customer_number) : "",
      row.identity_kind,
    ])
  );

  return mapped;
}

function schemaNotReady(req: Request): Response {
  return jsonResponse(req, {
    ok: false,
    error: "not_configured",
    message: "Subscription tables are not applied yet. Apply supabase-platform-subscriptions-v1.sql.",
  }, 503);
}

function parseSubscriptionWrite(body: JsonMap): {
  businessId: string;
  packageId: string | null;
  operation: SubscriptionOperation;
  startsOn: string | null;
  expiresOn: string | null;
  idempotencyKey: string | null;
  note: string | null;
} | { error: string } {
  const businessId = asTrimmed(body.business_id);
  if (!UUID_RE.test(businessId)) return { error: "invalid_business_id" };
  const operation = asTrimmed(body.operation).toLowerCase();
  if (!SUBSCRIPTION_OPERATIONS.includes(operation as SubscriptionOperation)) {
    return { error: "invalid_operation" };
  }
  const packageId = asTrimmed(body.package_id) || null;
  if (isPaidOperation(operation) && !packageId) return { error: "invalid_package_id" };

  const startsOn = body.starts_on == null || body.starts_on === ""
    ? null
    : parseDateOnly(body.starts_on);
  if (
    (isPaidOperation(operation) ||
      operation === "grant_complimentary" ||
      operation === "replace_complimentary" ||
      operation === "convert_to_complimentary") &&
    !startsOn
  ) {
    return { error: "invalid_starts_on" };
  }
  if (body.starts_on != null && body.starts_on !== "" && !startsOn) {
    return { error: "invalid_starts_on" };
  }

  let expiresOn: string | null = null;
  if (body.expires_on != null && body.expires_on !== "") {
    expiresOn = parseDateOnly(body.expires_on);
    if (!expiresOn) return { error: "invalid_expires_on" };
  }
  if (operation === "extend_complimentary" && !expiresOn) {
    return { error: "invalid_expires_on" };
  }

  const idempotencyRaw = asTrimmed(body.idempotency_key);
  const idempotencyKey = idempotencyRaw
    ? (UUID_RE.test(idempotencyRaw) ? idempotencyRaw : "invalid")
    : null;
  if (idempotencyKey === "invalid") return { error: "invalid_idempotency_key" };
  const noteRaw = asTrimmed(body.note);
  if (noteRaw.length > 500) return { error: "invalid_note" };
  return {
    businessId,
    packageId: isComplimentaryOperation(operation) && operation !== "convert_to_paid"
      ? null
      : packageId,
    operation: operation as SubscriptionOperation,
    startsOn,
    expiresOn,
    idempotencyKey,
    note: noteRaw || null,
  };
}

async function callSubscriptionRpc(
  admin: AdminClient,
  fn: "admin_preview_business_subscription" | "admin_apply_business_subscription",
  args: Record<string, unknown>,
): Promise<{ ok: true; data: Record<string, unknown> } | { ok: false; error: string }> {
  const { data, error } = await admin.rpc(fn, args);
  if (error) {
    if (isMissingFunctionError(error) || isMissingRelationError(error)) {
      return { ok: false, error: "not_configured" };
    }
    return { ok: false, error: "internal_error" };
  }
  const payload = asRpcObject(data);
  if (!payload) return { ok: false, error: "internal_error" };
  if (payload.ok === false) {
    return { ok: false, error: asTrimmed(payload.error) || "internal_error" };
  }
  return { ok: true, data: payload };
}

async function loadOverviewSubscriptions(
  admin: AdminClient,
  totalBusinesses: number,
): Promise<{
  available: boolean;
  active: number;
  expired: number;
  unconfigured: number;
  complimentary: number;
  paid_active: number;
}> {
  const currents = await loadCurrentSubscriptions(admin);
  if (currents === "missing") {
    return {
      available: false,
      active: 0,
      expired: 0,
      unconfigured: totalBusinesses,
      complimentary: 0,
      paid_active: 0,
    };
  }
  const summary = summarizeSubscriptions(totalBusinesses, currents, utcToday());
  return {
    available: true,
    active: summary.active,
    expired: summary.expired,
    unconfigured: summary.unconfigured,
    complimentary: summary.complimentary,
    paid_active: summary.paid_active,
  };
}

async function loadSubscriptionWorkspace(admin: AdminClient) {
  const [catalog, currents, businesses] = await Promise.all([
    loadPackageCatalog(admin),
    loadCurrentSubscriptions(admin),
    selectBusinesses(admin),
  ]);
  if (catalog === "missing" || currents === "missing") return null;

  const asOfDate = utcToday();
  const packageById = new Map(catalog.all.map((pkg) => [pkg.package_id, pkg]));
  const subscriptions = businesses.map((row) => {
    const mapped = mapBusiness(row);
    const current = currents.get(mapped.business_id);
    const pkg = current ? packageById.get(current.package_id) : undefined;
    return mapSubscriptionRecord(
      {
        business_id: mapped.business_id,
        business_name: mapped.business_name,
        business_slug: mapped.business_slug,
      },
      current,
      pkg,
      asOfDate,
    );
  }).sort((a, b) => a.business_name.localeCompare(b.business_name));

  return {
    as_of_date: asOfDate,
    packages: catalog.active,
    subscriptions,
    summary: summarizeSubscriptions(businesses.length, currents, asOfDate),
  };
}

async function loadSubscriptionForBusiness(
  admin: AdminClient,
  business: { business_id: string; business_name: string; business_slug: string | null },
) {
  const [catalog, currents] = await Promise.all([
    loadPackageCatalog(admin),
    loadCurrentSubscriptions(admin),
  ]);
  if (catalog === "missing" || currents === "missing") return "missing" as const;
  const current = currents.get(business.business_id);
  const pkg = current
    ? catalog.all.find((item) => item.package_id === current.package_id)
    : undefined;
  return mapSubscriptionRecord(business, current, pkg, utcToday());
}

async function loadHistoryForBusiness(admin: AdminClient, businessId: string) {
  const [rows, catalog] = await Promise.all([
    loadSubscriptionHistory(admin, businessId),
    loadPackageCatalog(admin),
  ]);
  if (rows === "missing" || catalog === "missing") return "missing" as const;
  const packageById = new Map(catalog.all.map((pkg) => [pkg.package_id, pkg]));
  const actorIds = rows.map((row) => asTrimmed(row.actor_user_id)).filter(Boolean);
  const emails = await emailsForUsers(admin, actorIds);
  return rows.map((row) => {
    const packageId = asTrimmed(row.package_id);
    return mapHistoryRow(
      row,
      packageById.get(packageId)?.label ?? null,
      emails.get(asTrimmed(row.actor_user_id)) || null,
    );
  });
}
