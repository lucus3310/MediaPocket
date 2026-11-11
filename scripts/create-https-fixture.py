"""Create an ephemeral identity for this CI Simulator's loopback HTTPS test."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1] / 'build/https-fixture'
root.mkdir(parents=True, exist_ok=True)
config = root / 'openssl.cnf'
config.write_text('''[req]
distinguished_name=dn
x509_extensions=extensions
prompt=no
[dn]
CN=localhost
[extensions]
subjectAltName=DNS:localhost,IP:127.0.0.1
basicConstraints=critical,CA:true
keyUsage=critical,keyCertSign,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
''')
subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2',
                '-config', str(config), '-keyout', str(root / 'localhost-key.pem'),
                '-out', str(root / 'localhost-cert.pem')], check=True, capture_output=True)
(root / 'localhost-key.pem').chmod(0o600)
subprocess.run(['openssl', 'x509', '-in', str(root / 'localhost-cert.pem'), '-outform', 'DER',
                '-out', str(root / 'localhost-cert.cer')], check=True)
print('Created ephemeral loopback TLS fixture under build/; never commit or ship it')
