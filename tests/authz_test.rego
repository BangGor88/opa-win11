package authz_test

import future.keywords.if

# ── OpenMetadata tests ─────────────────────────────────────────

test_om_admin_can_delete if {
  data.openmetadata.authz.allow with input as {
    "user": {"role": "admin"},
    "action": "delete",
    "resource": "any_table"
  }
}

test_om_analyst_can_read_normal if {
  data.openmetadata.authz.allow with input as {
    "user": {"role": "analyst"},
    "action": "read",
    "resource": "sales_table"
  }
}

test_om_analyst_blocked_from_pii if {
  not data.openmetadata.authz.allow with input as {
    "user": {"role": "analyst"},
    "action": "read",
    "resource": "customer_pii_table"
  }
}

test_om_analyst_cannot_write if {
  not data.openmetadata.authz.allow with input as {
    "user": {"role": "analyst"},
    "action": "write",
    "resource": "sales_table"
  }
}

test_om_viewer_blocked_from_sensitive if {
  not data.openmetadata.authz.allow with input as {
    "user": {"role": "viewer"},
    "action": "read",
    "resource": "sensitive_financials"
  }
}

test_om_unknown_role_denied if {
  not data.openmetadata.authz.allow with input as {
    "user": {"role": "unknown"},
    "action": "read",
    "resource": "sales_table"
  }
}

# ── Kafka tests ────────────────────────────────────────────────

test_kafka_admin_full_access if {
  data.kafka.authz.allow with input as {
    "user": {"role": "admin"},
    "action": "create_topic",
    "resource": "any_topic"
  }
}

test_kafka_analyst_can_consume_allowed_topic if {
  data.kafka.authz.allow with input as {
    "user": {"role": "analyst"},
    "action": "consume",
    "resource": "analytics_events"
  }
}

test_kafka_analyst_blocked_from_pii_topic if {
  not data.kafka.authz.allow with input as {
    "user": {"role": "analyst"},
    "action": "publish",
    "resource": "pii_events"
  }
}

test_kafka_analyst_blocked_from_internal_topic if {
  not data.kafka.authz.allow with input as {
    "user": {"role": "analyst"},
    "action": "publish",
    "resource": "internal_audit_log"
  }
}

test_kafka_analyst_blocked_from_unknown_topic if {
  not data.kafka.authz.allow with input as {
    "user": {"role": "analyst"},
    "action": "consume",
    "resource": "unknown_topic"
  }
}

# ── API Gateway tests ──────────────────────────────────────────

test_gateway_admin_can_delete if {
  data.gateway.authz.allow with input as {
    "user": {"role": "admin"},
    "action": "DELETE",
    "resource": "/api/admin/users"
  }
}

test_gateway_analyst_can_get_data if {
  data.gateway.authz.allow with input as {
    "user": {"role": "analyst"},
    "action": "GET",
    "resource": "/api/data/reports"
  }
}

test_gateway_analyst_cannot_post if {
  not data.gateway.authz.allow with input as {
    "user": {"role": "analyst"},
    "action": "POST",
    "resource": "/api/data/reports"
  }
}

test_gateway_viewer_can_read_public if {
  data.gateway.authz.allow with input as {
    "user": {"role": "viewer"},
    "action": "GET",
    "resource": "/api/public/dashboard"
  }
}

test_gateway_viewer_blocked_from_data if {
  not data.gateway.authz.allow with input as {
    "user": {"role": "viewer"},
    "action": "GET",
    "resource": "/api/data/reports"
  }
}

test_gateway_viewer_cannot_post_public if {
  not data.gateway.authz.allow with input as {
    "user": {"role": "viewer"},
    "action": "POST",
    "resource": "/api/public/dashboard"
  }
}