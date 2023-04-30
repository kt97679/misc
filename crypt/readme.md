# about

This is a simple self contained (no external dependnecies) encryption-decryption utility using
[Xoshiro256starstar](https://en.wikipedia.org/wiki/Xorshift#xoshiro256**)
for random number generation.

# demo

```
$ echo 0123456789 > /tmp/in
$ PASSWORD=01234567890123456789 ./crypt.py -i /tmp/in -o /tmp/out -e
$ hd /tmp/out
00000000  b6 ee ba 71 ca 02 00 2f  04 98 2e f2 2d e9 02 00  |...q.../....-...|
00000010  fc fd 4a a5 6e 53 ad 06  00 eb e7 d8 7e d0 f8 87  |..J.nS......~...|
00000020  05 00 55 d5 7c 43 bb d3  aa 06 00 6c d7 cb 4f 39  |..U.|C.....l..O9|
00000030  88 2e 05 00 57 0c 55 0b  53 94 ec 03 00 ad 58 8d  |....W.U.S.....X.|
00000040  b4 16 02 dc 02 00 79 8a  d3 76 e3 1f 83 03 00 e2  |......y..v......|
00000050  54 e2 aa ef de 00 04 00  3c 96 50 ad d2 f6 0a 00  |T.......<.P.....|
00000060  8a b9 da a1 8c 06 05 06  00 bf a4 c9 bb 21 14 01  |.............!..|
00000070  07 00 c2 e7 98 32 6f 44  43 05 00 36 95 9d 30 ae  |.....2oDC..6..0.|
00000080  20 d5 01 00 ad 2e d2 17  b9 40 be 05 00 bd 32 4b  | ........@....2K|
00000090  c2 c2 64 a6 01 00 47 bc  6c b0 22 d3 b4 00 f0 9f  |..d...G.l.".....|
000000a0  5d e3 bc 27 ca 08 00 0b  91 ca f3 1f 9b f8 05 00  |]..'............|
000000b0  32 fe aa d1 06 9f ee 02  00 1a 6c 0c a1 be bd 51  |2.........l....Q|
000000c0  05 00 67 90 4c 41 5c 96  38 00 04 a2 35 5a 75 9e  |..g.LA\.8...5Zu.|
000000d0  96 03 00 11 48 32 79 f0  73 ab 02 00 60 74 1c ee  |....H2y.s...`t..|
000000e0  7b 84 81 3f 38 f0 5b 59  cc 78 84 47 04 00 73 5f  |{..?8.[Y.x.G..s_|
000000f0  72 77 be 13 17 05 00 17  11 60 0a a9 41 b6 01 00  |rw.......`..A...|
00000100  74 c6 4b 25 3d e6 20 04  00 8b bf 20 59 00 8c 7c  |t.K%=. .... Y..||
00000110  07 00 c6 b0 25 36 e4 16  31 06 00 01 8f ec 03 6c  |....%6..1......l|
00000120  28 5f 08 00 2b de f7 d7  80 52 b1 06 00 b2 a7 9e  |(_..+....R......|
00000130  fe ab 1e f8 04 00 01 2c  d1 ae 0e 1e 07 05 00 5a  |.......,.......Z|
00000140  7a 05 29 13 ad 9d 06 00  3a 0b 76 57 a1 11 87 02  |z.).....:.vW....|
00000150  00 c5 80 af d1 6f 2b f4  06 00 d5 99 f6 06 e0 b3  |.....o+.........|
00000160  af 06 00 c8 e8 ff f0 6b  d2 a5 00 90 51 10 c9 c2  |.......k....Q...|
00000170  9a fe 02 00 33 73 09 40  4d e4 6b 06 00 4e d4 ec  |....3s.@M.k..N..|
00000180  71 0f df 71 01 00 68 68  9c 6e 29 49 bd 01 00 a3  |q..q..hh.n)I....|
00000190  a9 5d 0d 9a c6 6d 02 00  fb 88 09 21 48 87 30 01  |.]...m.....!H.0.|
000001a0  00 2c 0b a5 b6 e8 82 10  01 00 2e 00 50 4c f1 ac  |.,..........PL..|
000001b0  3f 06 00 c8 ff 42 00 4b  b1 f4 08 00 20 04 e7 e3  |?....B.K.... ...|
000001c0  0f 0e 25 05 00 29 7c db  fe 6d f0 5b 01 00 0a 91  |..%..)|..m.[....|
000001d0  dc e7 ab 2e 9c                                    |.....|
000001d5
$ PASSWORD=01234567890123456789 ./crypt.py -i /tmp/out -o /tmp/dec -d
$ hd /tmp/dec
00000000  30 31 32 33 34 35 36 37  38 39 0a                 |0123456789.|
0000000b
$ md5sum /tmp/in /tmp/dec
3749f52bb326ae96782b42dc0a97b4c1  /tmp/in
3749f52bb326ae96782b42dc0a97b4c1  /tmp/dec
$ 
```

# performance

```
$ dd if=/dev/zero of=/tmp/1g bs=$((1024*1024)) count=128
128+0 records in
128+0 records out
134217728 bytes (134 MB, 128 MiB) copied, 0.0974041 s, 1.4 GB/s
$ time PASSWORD=01234567890123456789 ./crypt.py -i /tmp/1g -o /tmp/1g.enc -e

real    1m34.638s
user    1m33.950s
sys     0m0.264s
$ lscpu |grep ^Model.name
Model name:                      Intel(R) Core(TM) i7-7600U CPU @ 2.80GHz
$ 

```
