"""Fixed local upstream for the actual CLI fixture, with host-only fake auth."""
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import threading

PROVIDER_KEY = 'host-only-FAKE-provider-NOT-VALID'
CURRENT = '/var/lib/claude-code-native-poc/current'
COMMAND = '/usr/bin/python3 -I -S /opt/claude-code-poc/native/work_fixture.py inheritance; /usr/bin/python3 -I -S /opt/claude-code-poc/native/work_fixture.py boundaries; /usr/bin/python3 -I -S /opt/claude-code-poc/native/work_fixture.py daemon; printf "native-fixture-started\\n"'
PLAN = [
    {'name': 'Write', 'input': {'file_path': CURRENT + '/work/native-fixture.txt', 'content': 'native fixture original\n'}},
    {'name': 'Read', 'input': {'file_path': CURRENT + '/work/native-fixture.txt'}},
    {'name': 'Edit', 'input': {'file_path': CURRENT + '/work/native-fixture.txt', 'old_string': 'original', 'new_string': 'edited', 'replace_all': False}},
    {'name': 'Bash', 'input': {'command': COMMAND, 'description': 'Fixed no-network native lifecycle fixture', 'timeout': 10000}},
    {'name': 'Read', 'input': {'file_path': CURRENT + '/controller/protected-fake.json'}},
    {'name': 'Write', 'input': {'file_path': CURRENT + '/controller/forbidden-create.txt', 'content': 'DENIED-NATIVE-FIXTURE\n'}},
]


class FakeMessages:
    def __init__(self):
        self.records = []
        self.lock = threading.Lock()
        outer = self
        class Handler(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def log_message(self, *_):
                pass  # Access data is recorded through the bounded structured fixture below.
            def do_POST(self):
                count = int(self.headers.get('Content-Length', '0'))
                if count <= 0 or count > 3_000_000:
                    self.send_error(413); return
                raw = self.rfile.read(count)
                body = json.loads(raw)
                authorized = self.headers.get('x-api-key') == PROVIDER_KEY
                results = {b.get('tool_use_id') for m in body.get('messages', [])
                           for b in m.get('content', []) if isinstance(m.get('content'), list) and isinstance(b, dict) and b.get('type') == 'tool_result'}
                with outer.lock:
                    outer.records.append({'path': self.path, 'method': 'POST', 'provider_auth_replaced': authorized,
                                          'request_bytes': len(raw), 'request_sha256': hashlib.sha256(raw).hexdigest(),
                                          'authorization_header_absent': self.headers.get('Authorization') is None,
                                          'header_names': sorted(self.headers.keys()), 'completed_tool_ids': sorted(results),
                                          'model': body.get('model')})
                    message_id = 'host-fake-' + str(len(outer.records))
                if not authorized:
                    self.send_error(403); return
                if self.path.split('?')[0] == '/v1/messages/count_tokens':
                    encoded = b'{"input_tokens":10}'
                    self.send_response(200); self.send_header('content-type', 'application/json')
                    self.send_header('content-length', str(len(encoded))); self.end_headers(); self.wfile.write(encoded); return
                index = next((i for i in range(len(PLAN)) if 'native-fixture-' + str(i) not in results), -1)
                block = {'type': 'tool_use', 'id': 'native-fixture-' + str(index), **PLAN[index]} if index >= 0 else {'type': 'text', 'text': 'Native fixture completed through authenticated host gateway.'}
                stop = 'tool_use' if index >= 0 else 'end_turn'
                message = {'id': message_id, 'type': 'message', 'role': 'assistant', 'model': 'claude-sonnet-4-6',
                           'content': [], 'stop_reason': None, 'stop_sequence': None,
                           'usage': {'input_tokens': 10, 'output_tokens': 0, 'cache_creation_input_tokens': 0, 'cache_read_input_tokens': 0}}
                if not body.get('stream'):
                    data = json.dumps({**message, 'content': [block], 'stop_reason': stop}).encode()
                    self.send_response(200); self.send_header('content-type', 'application/json'); self.send_header('content-length', str(len(data)))
                    self.end_headers(); self.wfile.write(data); return
                self.send_response(200); self.send_header('content-type', 'text/event-stream'); self.send_header('connection', 'close'); self.end_headers()
                frames = [('message_start', {'type': 'message_start', 'message': message}),
                          ('content_block_start', {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''} if block['type'] == 'text' else {**block, 'input': {}}}),
                          ('content_block_delta', {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': block['text']} if block['type'] == 'text' else {'type': 'input_json_delta', 'partial_json': json.dumps(block['input'])}}),
                          ('content_block_stop', {'type': 'content_block_stop', 'index': 0}),
                          ('message_delta', {'type': 'message_delta', 'delta': {'stop_reason': stop, 'stop_sequence': None}, 'usage': {'output_tokens': 10}}),
                          ('message_stop', {'type': 'message_stop'})]
                for name, frame in frames:
                    self.wfile.write(('event: ' + name + '\ndata: ' + json.dumps(frame) + '\n\n').encode()); self.wfile.flush()
                self.close_connection = True
        self.server = ThreadingHTTPServer(('127.0.0.1', 41419), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def start(self):
        self.thread.start()

    def stop(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join(timeout=3)

    def snapshot(self):
        with self.lock:
            return {'schema': 'host-fake-messages/v1', 'origin': 'http://127.0.0.1:41419',
                    'provider_key_is_fake': True, 'requests': list(self.records)}
