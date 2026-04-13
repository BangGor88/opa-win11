package kafka.authz

import future.keywords.if
import future.keywords.in

default allow = false

allow if { input.user.role == "admin" }

allow if {
  input.user.role in ["data_steward", "analyst"]
  input.action == "publish"
  not startswith(input.resource, "internal_")
  not startswith(input.resource, "pii_")
}

allow if {
  input.user.role == "analyst"
  input.action == "consume"
  input.resource in ["analytics_events", "product_clicks", "public_feed"]
}