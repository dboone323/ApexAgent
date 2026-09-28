# MCPKit (experimental)

This module is an **experimental, duplicate MCP stack**. It is NOT the production path.

## What lives here

- `MCPClient.swift` — a naive ~56-line reference MCP client (plain `URLSession`, no
  timeouts, no retries, no circuit-breaker, no health probing). Kept only for
  experimentation and local tooling.
- `MCPServerListener.swift` — a hand-rolled unauthenticated HTTP/1.1 listener that
  executes tool handlers. It binds **loopback-only** so it never reaches the LAN,
  but any local process can still invoke the handler with no authentication. Do not
  expose it on a network interface or use it for production traffic.

## What production code must use instead

The hardened client in `ApexAgent/Models/MCPClient.swift` (timeouts, retry with
backoff, circuit-breaker, health probing) and the authenticated production servers.
New code must not import this module for app behavior.

## Follow-up

Consolidating the two stacks (removing or promoting this module) is tracked as
follow-up work; this README + the in-code deprecation notes are the safe first step.
