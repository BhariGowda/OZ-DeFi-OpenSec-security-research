# ThetanutsFi Exploit - Jun 15 2026

Exploit TX: 0xbba9f138fe39503bfd1aa62932dbd6ab35d37d23d48e4b7bf2988a9d5dc39fec
Block: 25323329
Attacker EOA: 0x30498e4466789E534c72e03B52A16c978655b41e
Deployed exploit contract: 0xa589c5342068B0C1fEFd44d3c95354427502AC91
Vulnerable vault: 0xc2c3ae0a7b405058558c9b4a63b373486cb86ac7
Secondary contract: 0x2ca7641b841a79cc70220ce838d0b9f8197accda

Root cause: Integer division truncation in mint(uint256)
after claim(uint256) drained vault to near-zero totalSupply
depositAmount = vault.balance * amount / totalSupply → 0

White Hat TX: 0x4c0a75e27855f350c95e3dc64906b1b2f19e6649fdfd0d9374f3915067418bc1
Lost: ~$2.1M, rescued: ~$2M

References:
- https://x.com/SlowMist_Team/status/2066548856138...
- https://x.com/ThetanutsFi/status/2066569315961454925
- Tenderly: https://dashboard.tenderly.co/tx/mainnet/0xbba9f138fe39503bfd1aa62932dbd6ab35d37d23d48e4b7bf2988a9d5dc39fec
