package openmetadata.authz

import future.keywords.if
import future.keywords.in

default allow = false

allow if { input.user.role == "admin" }

allow if {
  input.user.role == "data_steward"
  input.action in ["read", "write"]
}

allow if {
  input.user.role == "analyst"
  input.action == "read"
  not contains(input.resource, "pii")
}