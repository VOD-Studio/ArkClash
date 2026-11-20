package main

import (
	"bufio"
	"bytes"
	"errors"
	"io"
	"strings"

	"github.com/metacubex/age"
	"github.com/metacubex/age/armor"
)

const ageBinaryHeader = "age-encryption.org/v1\n"

var errAgeRequired = errors.New("age_required")
var errAgeDecrypt = errors.New("age_decrypt")

func subscriptionBody(body io.Reader, secretKey string, limit int64) (io.Reader, error) {
	buffered := bufio.NewReader(io.LimitReader(body, limit+1))
	header, _ := buffered.Peek(len(armor.Header))
	armored := bytes.HasPrefix(header, []byte(armor.Header))
	if !armored && !bytes.HasPrefix(header, []byte(ageBinaryHeader)) {
		return buffered, nil
	}
	if strings.TrimSpace(secretKey) == "" {
		return nil, errAgeRequired
	}
	identities, err := age.ParseIdentities(strings.NewReader(secretKey))
	if err != nil {
		return nil, errAgeDecrypt
	}
	var encrypted io.Reader = buffered
	if armored {
		encrypted = armor.NewReader(buffered)
	}
	plain, err := age.Decrypt(encrypted, identities...)
	if err != nil {
		return nil, errAgeDecrypt
	}
	return ageSubscriptionReader{plain}, nil
}

type ageSubscriptionReader struct{ io.Reader }

func (r ageSubscriptionReader) Read(p []byte) (int, error) {
	n, err := r.Reader.Read(p)
	if err != nil && err != io.EOF {
		return n, errAgeDecrypt
	}
	return n, err
}
