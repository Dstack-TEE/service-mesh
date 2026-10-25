package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	dstack "github.com/Dstack-TEE/dstack/sdk/go/dstack"
)

func TestReportDataBindsStatementAndNonce(t *testing.T) {
	statement := []byte(`{"identity":"spiffe://demo/webdemo"}`)
	nonce := "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
	got, err := reportData(statement, nonce)
	if err != nil {
		t.Fatal(err)
	}
	nonceBytes, _ := hex.DecodeString(nonce)
	h := sha256.New()
	h.Write(statement)
	h.Write(nonceBytes)
	want := make([]byte, 64)
	copy(want, h.Sum(nil))
	if !bytes.Equal(got, want) {
		t.Fatalf("report data mismatch")
	}
}

func TestReportDataRejectsWrongNonceSize(t *testing.T) {
	_, err := reportData([]byte("{}"), "abcd")
	if err == nil {
		t.Fatal("expected error")
	}
}

func TestSplitCSV(t *testing.T) {
	got := splitCSV(" http://a, ,http://b ")
	if len(got) != 2 || got[0] != "http://a" || got[1] != "http://b" {
		t.Fatalf("bad split: %#v", got)
	}
}

func TestAdmitRetriesTransientBrokerFailure(t *testing.T) {
	prevRetry := admissionRetryInterval
	admissionRetryInterval = 10 * time.Millisecond
	t.Cleanup(func() { admissionRetryInterval = prevRetry })

	var challenges atomic.Int32
	broker := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/admission/challenge":
			if challenges.Add(1) == 1 {
				http.Error(w, "not ready", http.StatusBadGateway)
				return
			}
			w.Write([]byte(`{"nonce":"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"}`))
		case "/v1/admission/attest":
			var payload attestRequest
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				t.Fatalf("decode attest request: %v", err)
			}
			if payload.Attestation != "aabbcc" {
				t.Fatalf("wrong attestation: %q", payload.Attestation)
			}
			w.Write([]byte(`{"consul_acl_token":"issued-token"}`))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(broker.Close)

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	client := &fakeAttestationClient{}
	statement := []byte(`{"ok":true}`)
	token, err := admit(ctx, broker.Client(), client, []string{broker.URL}, "spiffe://demo/webdemo", statement)
	if err != nil {
		t.Fatal(err)
	}
	if token != "issued-token" {
		t.Fatalf("wrong token: %q", token)
	}
	if got := challenges.Load(); got != 2 {
		t.Fatalf("expected one retry, got %d challenge requests", got)
	}
	wantReportData, err := reportData(statement, "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(client.reportData, wantReportData) {
		t.Fatal("Attest did not receive the binding statement and nonce digest")
	}
}

func TestAdmitDoesNotRetryPermanentBrokerRejection(t *testing.T) {
	prevRetry := admissionRetryInterval
	admissionRetryInterval = 10 * time.Millisecond
	t.Cleanup(func() { admissionRetryInterval = prevRetry })

	var challenges atomic.Int32
	broker := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		challenges.Add(1)
		http.Error(w, "admission rejected", http.StatusForbidden)
	}))
	t.Cleanup(broker.Close)

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_, err := admit(ctx, broker.Client(), &fakeAttestationClient{}, []string{broker.URL}, "spiffe://demo/webdemo", []byte(`{"ok":true}`))
	if err == nil {
		t.Fatal("expected error")
	}
	if got := challenges.Load(); got != 1 {
		t.Fatalf("permanent rejection should not be retried, got %d challenge requests", got)
	}
}

type fakeAttestationClient struct {
	reportData []byte
}

func (f *fakeAttestationClient) Attest(_ context.Context, reportData []byte) (*dstack.AttestResponse, error) {
	f.reportData = append([]byte(nil), reportData...)
	return &dstack.AttestResponse{Attestation: []byte{0xaa, 0xbb, 0xcc}}, nil
}
