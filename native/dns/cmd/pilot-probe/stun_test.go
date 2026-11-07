package main

import "testing"

func TestSTUNReply(t *testing.T) {
	q := []byte{0, 1, 0, 0, 0x21, 0x12, 0xa4, 0x42, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}
	r := append([]byte(nil), q...)
	r[0] = 1
	if !validSTUNReply(r, q) {
		t.Fatal("matching binding reply rejected")
	}
	for _, index := range []int{0, 1, 2, 3, 4, 8, 19} {
		bad := append([]byte(nil), r...)
		bad[index] ^= 1
		if validSTUNReply(bad, q) {
			t.Fatalf("accepted corrupted response field %d", index)
		}
	}
	if validSTUNReply(r[:19], q) || validSTUNReply(append(r, 0), q) {
		t.Fatal("accepted truncated/extra payload")
	}
}
