package gateway.authz

import future.keywords.if
import future.keywords.in

default allow = false

allow if { input.user.role == "admin" }

allow if {
  input.user.role in ["analyst", "data_steward"]
  input.action in ["GET", "HEAD", "OPTIONS"]
  startswith(input.resource, "/api/data/")
}

allow if {
  input.user.role == "data_steward"
  input.action == "POST"
  startswith(input.resource, "/api/data/")
}

allow if {
  input.user.role == "viewer"
  input.action == "GET"
  startswith(input.resource, "/api/public/")
}