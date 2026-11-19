#!/bin/bash
# Prints the VNC connection details once the ngrok tunnel is up.

URL=""
for i in $(seq 1 30); do
  URL=$(curl -s http://localhost:4040/api/tunnels | grep -o '"public_url":"[^"]*' | sed 's/"public_url":"//')
  [ -n "$URL" ] && break
  sleep 2
done

echo ..........................................................
echo "VNC address (use host:port, drop the tcp://):"
echo "${URL:-<tunnel not up yet - check ngrok.log>}"
echo "VNC password (what the VNC client asks for): P@ssw0rd"
echo "If a macOS login window appears -> Username: runneradmin  Password: P@ssw0rd!"
echo ..........................................................
