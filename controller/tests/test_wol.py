import pytest

from wake.wol import build_magic_packet, parse_mac


def test_parse_mac_accepts_common_formats():
    expected = bytes.fromhex("aabbccddeeff")
    assert parse_mac("aa:bb:cc:dd:ee:ff") == expected
    assert parse_mac("AA-BB-CC-DD-EE-FF") == expected
    assert parse_mac("aabb.ccdd.eeff") == expected


@pytest.mark.parametrize("bad", ["", "aa:bb:cc", "zz:bb:cc:dd:ee:ff", "aa:bb:cc:dd:ee:ff:00"])
def test_parse_mac_rejects_invalid(bad):
    with pytest.raises(ValueError):
        parse_mac(bad)


def test_magic_packet_is_6_ff_then_16_macs():
    packet = build_magic_packet("01:02:03:04:05:06")
    assert len(packet) == 102
    assert packet[:6] == b"\xff" * 6
    assert packet[6:] == bytes.fromhex("010203040506") * 16
