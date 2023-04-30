#!/usr/bin/env python

import os
import argparse
import getpass

MASK_64BIT = (1 << 64) - 1
BUF_SIZE = 1024 * 32

# https://en.wikipedia.org/wiki/Xorshift#xoshiro256**
class Xoshiro256starstar:
    def __init__(self, password):
        self.state = [0, 0, 0, 0]
        password_bytes = password.encode("utf-8")
        seed = int.from_bytes(password_bytes, byteorder='big')
        i = 0
        while seed > 0:
            self.state[i % 4] ^= (seed & MASK_64BIT)
            seed >>= 64
            i += 1
        i = 0
        for ch in password:
            i = (i * 23 // 17) + ord(ch)
        while i > 0:
            self.next()
            i -= 1

    def _rotl(self, x, k):
        return (((x << k) & MASK_64BIT) | (x >> (64 - k)))

    def next(self):
        self.random_bits = 0
        result_starstar = self._rotl(self.state[1] * 5, 7) * 9
        t = (self.state[1] << 17) & MASK_64BIT

        self.state[2] ^= self.state[0]
        self.state[3] ^= self.state[1]
        self.state[1] ^= self.state[2]
        self.state[0] ^= self.state[3]

        self.state[2] ^= t

        self.state[3] = self._rotl(self.state[3], 45)

        return result_starstar

    def next_byte(self):
        self.random_bits = self.random_bits >> 8
        if self.random_bits == 0:
            self.random_bits = self.next() >> 8 # least significant bits have low quality
        return self.random_bits & 255

class Crypt():
    def encrypt(self):
        with open(self.input_file, 'rb') as in_file:
            with open(self.output_file, 'wb') as out_file:
                head = []
                while self.head_count > 0:
                    head.append(self.rng.next_byte())
                    self.head_count -= 1
                out_file.write(bytes(head))
                while True:
                    in_buf = in_file.read(BUF_SIZE)
                    out_buf = []
                    if not in_buf:
                        break
                    for buf_byte in in_buf:
                        out_buf.append(buf_byte ^ self.rng.next_byte())
                    out_file.write(bytes(out_buf))
                tail = []
                while self.tail_count > 0:
                    tail.append(self.rng.next_byte())
                    self.tail_count -= 1
                out_file.write(bytes(tail))

    def decrypt(self):
        with open(self.input_file, 'rb') as in_file:
            with open(self.output_file, 'wb') as out_file:
                in_buf = in_file.read(self.head_count)
                in_file_size = os.path.getsize(self.input_file)
                bytes_to_read = in_file_size - self.head_count - self.tail_count
                bytes_processed = 0
                while self.head_count > 0:
                    self.rng.next_byte()
                    self.head_count -= 1
                while bytes_processed < bytes_to_read:
                    in_buf_len = min(BUF_SIZE, bytes_to_read - bytes_processed)
                    in_buf = in_file.read(in_buf_len)
                    bytes_processed += in_buf_len
                    out_buf = []
                    for buf_byte in in_buf:
                        out_buf.append(buf_byte ^ self.rng.next_byte())
                    out_file.write(bytes(out_buf))

    def parse_args(self):
        parser = argparse.ArgumentParser()
        parser.add_argument('--input-file', '-i', required=True, help='File to read data from')
        parser.add_argument('--output-file', '-o', required=True, help='File to write data to')
        group = parser.add_mutually_exclusive_group(required=True)
        group.add_argument('--decrypt', '-d', dest='action', action='store_const', const='decrypt', help='Decrypt data')
        group.add_argument('--encrypt', '-e', dest='action', action='store_const', const='encrypt', help='Encrypt data')
        return parser.parse_args()

    def run(self):
        args = self.parse_args()
        self.input_file = args.input_file
        self.output_file = args.output_file
        password = os.environ.get('PASSWORD')
        if not password:
            password = getpass.getpass('Enter password: ')
        self.rng = Xoshiro256starstar(password)
        self.head_count = self.rng.next_byte()
        self.tail_count = self.rng.next_byte()
        getattr(self, args.action)()

Crypt().run()
