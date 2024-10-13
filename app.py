#!/usr/bin/env python

import re
import collections
import os
import socket
from functools import wraps

from flask import Flask
from dotenv import load_dotenv

import dns.resolver
import dns.tsigkeyring
import dns.inet
import dns.update
import dns.query

load_dotenv()

def get_record_type(address):
    inet_af = dns.inet.af_for_address(address)
    af_type = {
        socket.AF_INET: 'A',
        socket.AF_INET6: 'AAAA'
    }
    return af_type.get(inet_af, 2)

def get_full_ptr(ip):
    return "{}.{}.{}.{}.in-addr.arpa".format(*ip.split('.')[::-1])

def is_valid_hostname(hostname):
    if len(hostname) > 255:
        return False
    if hostname[-1] == ".":
        hostname = hostname[:-1] # strip exactly one dot from the right, if present
    allowed = re.compile(r"(?!-)[A-Z\d-]{1,63}(?<!-)$", re.IGNORECASE)
    return all(allowed.match(x) for x in hostname.split("."))

class DnsServer:
    def __init__(self, address, zone, keyring):
        self.address = address
        self.zone = zone
        self.keyring = keyring
        self.default_ttl = 3600

        self.resolver = dns.resolver.Resolver()
        self.resolver.nameservers = [self.address]

    def get_fqdn(self, name):
        return f'{name}.{self.zone}.'

    def query_name(self, name, rtype='A'):
        result = collections.defaultdict(set)
        try:
            answers = self.resolver.resolve(name, rtype)
        except dns.resolver.NXDOMAIN:
            return None
        return [str(rdata) for rdata in answers]

    def query_address(self, address):
        try:
            response = self.resolver.resolve_address(address)
        except dns.resolver.NXDOMAIN:
            return []
        return [str(answer) for answer in response]

    def update(self, name, value, type, ttl=None):
        if not ttl:
            ttl = self.default_ttl
        updater = dns.update.UpdateMessage(self.zone, keyring=self.keyring)
        updater.replace(name, ttl, type, value)
        dns.query.tcp(updater, self.address)

    def delete(self, name):
        updater = dns.update.UpdateMessage(self.zone, keyring=self.keyring)
        updater.delete(name)
        dns.query.tcp(updater, self.address)

TSIG_keyring = dns.tsigkeyring.from_text({
    os.getenv('TSIG_KEYNAME'): os.getenv('TSIG_SECRET')
})
DNS = DnsServer(
    os.getenv('DNS_SERVER'),
    os.getenv('DNS_ZONE'),
    TSIG_keyring
)

def middleware(*checks):
    def decorator(func):
        for check in reversed(checks):
            func = check(func)
        return func
    return decorator

def handle_error(func):
    @wraps(func)
    def wrapper(*args, **kwargs):
        try:
            return func(*args, **kwargs)
        except Exception as exception:
            print(exception)
            return "Error", 500
    return wrapper


app = Flask(__name__)

@app.route('/')
def home():
    return 'Mikrotik DHCP DNS Updater'

@app.route('/query/<name>/<type>')
@middleware(handle_error)
def query(name, type):
    result = DNS.query_name(name, rtype=type)
    return '\n'.join([str(x) for x in result])

@app.route('/update/<name>/<address>')
@app.route('/update/<name>/<address>/<ttl>')
@middleware(handle_error)
def update(name, address, ttl=None):
    record_type = get_record_type(address)
    fqdn = DNS.get_fqdn(name)
    if not ttl:
        ttl = os.getenv('DHCP_TTL')
    DNS.update(fqdn, address, record_type, ttl=ttl)
    return "Ok"

@app.route('/delete/<name>')
@middleware(handle_error)
def delete(name):
    fqdn = DNS.get_fqdn(name)
    DNS.delete(fqdn)
    return "Ok"

if __name__ == '__main__':
    app.run(host='0.0.0.0')
