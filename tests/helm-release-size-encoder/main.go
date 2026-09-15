// Command helm-release-size-encoder reports how many bytes Helm stores for one
// release record.
//
// Helm keeps every release revision in a Kubernetes Secret whose data value is
// base64(gzip(json(release))), produced by encodeRelease in Helm's storage
// driver with encoding/json, compress/gzip at BestCompression and
// encoding/base64. Kubernetes refuses a Secret whose data exceeds 1,048,576
// bytes. This program applies the same three standard library steps to a
// release record read from standard input and prints the resulting length, so
// a chart can be checked against that limit without a cluster.
//
// The input must be the JSON release record that
// `helm install <release> <chart> --dry-run=client --output=json` prints. It
// is not `helm template` output: the stored record embeds the chart itself
// (every template and file, including payloads read by .Files.Get) next to
// the rendered manifest, and only the record carries both.
package main

import (
	"bytes"
	"compress/gzip"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"os"
)

func main() {
	input, err := io.ReadAll(os.Stdin)
	if err != nil {
		fail(fmt.Errorf("reading standard input: %w", err))
	}

	// A release record always carries the chart; Helm omits the manifest
	// field when nothing rendered, so the chart is the discriminator.
	var record struct {
		Chart json.RawMessage `json:"chart"`
	}
	if err := json.Unmarshal(input, &record); err != nil {
		fail(fmt.Errorf("input is not a JSON release record (%w); "+
			"pass the output of helm install --dry-run=client --output=json, not helm template", err))
	}
	if len(record.Chart) == 0 || string(record.Chart) == "null" {
		fail(fmt.Errorf("input is not a Helm release record: it carries no \"chart\" field; " +
			"pass the output of helm install --dry-run=client --output=json, not helm template"))
	}

	// The record is already compact JSON, as json.Marshal writes it; compacting
	// again only removes whitespace a caller may have added around it.
	var compact bytes.Buffer
	if err := json.Compact(&compact, input); err != nil {
		fail(fmt.Errorf("compacting the release record: %w", err))
	}

	var compressed bytes.Buffer
	writer, err := gzip.NewWriterLevel(&compressed, gzip.BestCompression)
	if err != nil {
		fail(err)
	}
	if _, err := writer.Write(compact.Bytes()); err != nil {
		fail(fmt.Errorf("compressing the release record: %w", err))
	}
	if err := writer.Close(); err != nil {
		fail(fmt.Errorf("compressing the release record: %w", err))
	}

	fmt.Printf(
		"json_bytes=%d gzip_bytes=%d encoded_bytes=%d\n",
		compact.Len(),
		compressed.Len(),
		base64.StdEncoding.EncodedLen(compressed.Len()),
	)
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "helm-release-size-encoder:", err)
	os.Exit(1)
}
