#!/bin/zsh
# Mock MCP server for testMCPClient: echoes a valid JSON-RPC response for every
# request it receives (initialize / tools/list), echoing back the exact id the
# client sent. Notifications (no id) are ignored. Keeps the client handshake from
# blocking on a missing response. Method names may arrive JSON-escaped (e.g.
# "tools\/list"), so the matcher tolerates the escaped slash.
while IFS= read -r line; do
    id=$(printf '%s' "$line" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
    if printf '%s' "$line" | grep -q '"method":"initialize"'; then
        echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"serverInfo\":{\"name\":\"MockServer\",\"version\":\"1.0.0\"}}}"
    elif printf '%s' "$line" | grep -q '"method":"tools.*list"'; then
        echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"tools\":[{\"name\":\"mock_tool\",\"description\":\"A mock tool\",\"inputSchema\":{\"type\":\"object\",\"properties\":{},\"required\":[]}}]}}"
    fi
done
