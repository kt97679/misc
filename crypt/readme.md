# about

This is a simple self contained (no external dependnecies) encryption-decryption utility using
[Xoshiro256starstar](https://en.wikipedia.org/wiki/Xorshift#xoshiro256**)
for random number generation.

# how this works

Pseudo random number generator (prng) is initialized with the state derived
from the current time. This state is stored in the encrypted file to be used
during decryption.  Initial state bytes are xored with password bytes to get
uniq state. Password is used to calculate number of warm up cycles for the
prng. Each added character doubles number of warm up cycles. Encrypted text is
prepended with random data of random length from 1 to 256 bytes to hide actual
length of the encrypted data. Random skip is used between bytes so there is no
way to reconstruct prng state from this added data. With random header added to
the encrypted file we start to xor input bytes with random bytes from the prng.

# compiling

```
$ gcc -O2 -o crypt crypt.c
```

# demo

```
$ echo "this is a test text" >/tmp/in
$ PASSWORD=01234567890123456789 ./crypt -i /tmp/in -o /tmp/out -e && hd /tmp/out
00000000  00 00 7b e2 76 87 09 63  4e f6 50 32 46 11 a1 3f  |..{.v..cN.P2F..?|
00000010  d1 d9 6a 30 31 43 9a d6  35 c2 77 a9 bc d0 42 14  |..j01C..5.w...B.|
00000020  d3 7f ac                                          |...|
00000023
$ PASSWORD=01234567890123456789 ./crypt -i /tmp/out -o /tmp/dec -d && hd /tmp/dec
00000000  74 68 69 73 20 69 73 20  61 20 74 65 73 74 20 74  |this is a test t|
00000010  65 78 74 0a                                       |ext.|
00000014
$ md5sum /tmp/in /tmp/dec
8dbe2272f977adbed1519e916d6a7d6a  /tmp/in
8dbe2272f977adbed1519e916d6a7d6a  /tmp/dec
$ 

```

# performance

```
$ dd if=/dev/zero of=/tmp/1g bs=$((1024*1024)) count=1024

1024+0 records in
1024+0 records out
1073741824 bytes (1.1 GB, 1.0 GiB) copied, 2.32278 s, 462 MB/s
$ time PASSWORD=0123456789 ./crypt -i /tmp/1g -o /tmp/1g.enc -e

real    0m6.111s
user    0m2.585s
sys     0m1.248s
$ md5sum /tmp/1g <(PASSWORD=0123456789 ./crypt -i /tmp/1g.enc -d)
cd573cfaace07e7949bc0c46028904ff  /tmp/1g
cd573cfaace07e7949bc0c46028904ff  /dev/fd/63
$ lscpu |grep ^Model.name
Model name:                      Intel(R) Core(TM) i7-7600U CPU @ 2.80GHz
$ 
```
