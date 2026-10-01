"""Local custom-tool example: python3 examples/order_tool_server.py [port]."""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class OrderToolHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if self.path != '/tool' or not 0 < length <= 16_384:
                self.send_error(400, 'Use POST /tool with a bounded JSON body')
                return
            payload = json.loads(self.rfile.read(length))
            if payload.get('toolName') != 'lookupOrder':
                self.send_error(400, 'Unknown tool')
                return
            order_id = payload['arguments']['orderID']
            status = 'delivered' if order_id == 'A-104' else 'unknown'
            response = json.dumps({'orderID': order_id, 'status': status}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(response)))
            self.end_headers()
            self.wfile.write(response)
        except (KeyError, TypeError, ValueError):
            self.send_error(400, 'Expected toolName and arguments.orderID')


if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 19000
    with HTTPServer(('127.0.0.1', port), OrderToolHandler) as server:
        print(f'Order tool listening at http://127.0.0.1:{port}/tool', flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
