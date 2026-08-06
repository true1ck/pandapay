#!/bin/bash
cd "$(dirname "$0")"
exec flutter run -d chrome --web-port 5173
