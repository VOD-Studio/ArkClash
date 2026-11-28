package subfetch

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"testing"

	"github.com/metacubex/age"
	"github.com/metacubex/age/armor"
)

func TestSubscriptionAgeBody(t *testing.T) {
	key, err := age.GenerateX25519Identity()
	if err != nil {
		t.Fatal(err)
	}
	other, err := age.GenerateX25519Identity()
	if err != nil {
		t.Fatal(err)
	}
	plain := []byte("proxies: []\nrules: ['MATCH,DIRECT']\n")
	for _, tc := range []struct {
		name    string
		armored bool
	}{{"binary", false}, {"armored", true}} {
		t.Run(tc.name, func(t *testing.T) {
			var data bytes.Buffer
			var dst io.Writer = &data
			if tc.armored {
				dst = armor.NewWriter(&data)
			}
			w, err := age.Encrypt(dst, key.Recipient())
			if err != nil {
				t.Fatal(err)
			}
			if _, err := w.Write(plain); err != nil {
				t.Fatal(err)
			}
			if err := w.Close(); err != nil {
				t.Fatal(err)
			}
			if tc.armored {
				if err := dst.(io.Closer).Close(); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := SubscriptionBody(bytes.NewReader(data.Bytes()), "", Limit); !errors.Is(err, ErrAgeRequired) {
				t.Fatalf("missing identity: %v", err)
			}
			if _, err := SubscriptionBody(bytes.NewReader(data.Bytes()), other.String(), Limit); !errors.Is(err, ErrAgeDecrypt) {
				t.Fatalf("wrong identity: %v", err)
			}
			r, err := SubscriptionBody(bytes.NewReader(data.Bytes()), key.String(), Limit)
			if err != nil {
				t.Fatal(err)
			}
			got, err := io.ReadAll(r)
			if err != nil || !bytes.Equal(got, plain) {
				t.Fatalf("decrypted body mismatch: %v", err)
			}
			truncated, err := SubscriptionBody(bytes.NewReader(data.Bytes()[:data.Len()-40]), key.String(), Limit)
			if err != nil {
				t.Fatal(err)
			}
			target := filepath.Join(t.TempDir(), "candidate")
			if err := WriteBody(target, truncated, Limit); !errors.Is(err, ErrAgeDecrypt) {
				t.Fatalf("truncated body: %v", err)
			}
			if _, err := os.Stat(target); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("failed download left a candidate: %v", err)
			}
		})
	}
	r, err := SubscriptionBody(bytes.NewReader(plain), "", Limit)
	if err != nil {
		t.Fatal(err)
	}
	got, err := io.ReadAll(r)
	if err != nil || !bytes.Equal(got, plain) {
		t.Fatalf("plaintext body mismatch: %v", err)
	}
}
