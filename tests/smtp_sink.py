"""Servidor SMTP local de pruebas. Guarda mensajes .eml, nunca los reenvía."""
import argparse
import socketserver
import ssl
from pathlib import Path
from uuid import uuid4


class SmtpHandler(socketserver.StreamRequestHandler):
    def handle(self):
        def reply(message):
            self.wfile.write(message + b"\r\n")

        tls = False
        reply(b"220 ecoruta-test ESMTP")
        while line := self.rfile.readline(8192):
            cmd, _, value = line.strip().partition(b" ")
            cmd = cmd.upper()
            if cmd == b"EHLO":
                reply(b"250-ecoruta-test")
                reply(b"250 AUTH PLAIN" if tls else b"250 STARTTLS")
            elif cmd == b"STARTTLS" and not tls:
                reply(b"220 Ready for TLS")
                self.rfile.close()
                self.wfile.close()
                self.connection = self.server.tls.wrap_socket(self.connection, server_side=True)
                self.rfile = self.connection.makefile("rb")
                self.wfile = self.connection.makefile("wb", buffering=0)
                tls = True
            elif cmd == b"AUTH" and tls:
                if b" " not in value:
                    reply(b"334 ")
                    self.rfile.readline(8192)
                reply(b"235 Authentication accepted by the test server")
            elif cmd in (b"MAIL", b"RCPT", b"RSET") and tls:
                reply(b"250 OK")
            elif cmd == b"DATA" and tls:
                reply(b"354 End with <CRLF>.<CRLF>")
                message = bytearray()
                while raw := self.rfile.readline(8192):
                    if raw == b".\r\n":
                        (self.server.output / f"{uuid4()}.eml").write_bytes(message)
                        reply(b"250 Queued by the test server")
                        break
                    message.extend(raw[1:] if raw.startswith(b"..") else raw)
            elif cmd == b"QUIT":
                reply(b"221 Bye")
                return
            else:
                reply(b"503 Unsupported command or TLS required")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cert")
    parser.add_argument("key")
    parser.add_argument("output", type=Path)
    parser.add_argument("--port", type=int, default=1587)
    args = parser.parse_args()
    with socketserver.ThreadingTCPServer(("127.0.0.1", args.port), SmtpHandler) as server:
        server.tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        server.tls.load_cert_chain(args.cert, args.key)
        server.output = args.output
        server.serve_forever()
