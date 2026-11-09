import http.server, os, sys, time

# Serves this directory to the guest and takes PUT uploads into ./in.
#
# Served text files get the token DROPBOX_TOKEN rewritten to the base URL the
# guest actually used to reach us (from the request's Host header), so guest
# scripts never carry a hardcoded host address: the Wi-Fi address moves
# (192.168.0.143 -> .144 -> .145 so far) and every stale copy cost a debugging
# round trip.  Write `@DROPBOX@/foo.ps1` in a .cmd/.ps1/.html and it arrives as
# `http://192.168.0.145:8765/foo.ps1`.
DROPBOX_TOKEN = b'@DROPBOX@'
REWRITTEN_SUFFIXES = ('.cmd', '.ps1', '.bat', '.html', '.js', '.txt', '.sh')
APPEND_UPLOADS = ('aqlog.txt', 'bench.txt', 'cadence.txt', 'jitter.txt', 'webgpu-setup.txt', 'clockline.txt', 'godot-setup.txt')
PORT = int(os.environ.get('EGG_DROPBOX_PORT', '8765'))


class H(http.server.SimpleHTTPRequestHandler):
    def do_PUT(self):
        n = int(self.headers.get('Content-Length', 0)); body = self.rfile.read(n)
        name = os.path.basename(self.path.split('?')[0]) or 'upload.txt'
        mode = 'ab' if name in APPEND_UPLOADS else 'wb'
        open(os.path.join('in', name), mode).write(body)
        if mode == 'ab':
            # Host arrival time per appended upload: a guest whose clock
            # stalls still stamps its lines in its own time; this is ours.
            open(os.path.join('in', 'arrivals.log'), 'a').write(
                time.strftime('%Y-%m-%dT%H:%M:%S ') + name + ' ' + body.decode('utf-8', 'replace').strip().splitlines()[-1][:120] + '\n')
        self.send_response(201); self.cors(); self.end_headers()

    # A page served from the guest's own localhost (WebGPU needs a secure
    # context) PUTs here cross-origin, which makes the browser preflight.
    def do_OPTIONS(self):
        self.send_response(204); self.cors(); self.end_headers()

    def cors(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, PUT, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', '*')

    def send_head(self):
        path = self.translate_path(self.path)
        if not path.endswith(REWRITTEN_SUFFIXES) or not os.path.isfile(path):
            return super().send_head()
        with open(path, 'rb') as f:
            body = f.read()
        if DROPBOX_TOKEN in body:
            host = self.headers.get('Host') or ('127.0.0.1:%d' % PORT)
            body = body.replace(DROPBOX_TOKEN, ('http://%s' % host).encode())
        self.send_response(200)
        self.send_header('Content-Type', self.guess_type(path))
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.cors()
        self.end_headers()
        import io
        return io.BytesIO(body)

    def log_message(self, f, *a): sys.stderr.write("%s %s\n" % (self.address_string(), f % a))


os.makedirs('in', exist_ok=True)
http.server.ThreadingHTTPServer(('0.0.0.0', PORT), H).serve_forever()
