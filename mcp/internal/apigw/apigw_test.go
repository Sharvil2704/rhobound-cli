// SPDX-License-Identifier: Apache-2.0

package apigw

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"reflect"
	"strings"
	"testing"
)

// The sample events of the API Gateway developer guide ("Working with AWS Lambda proxy integrations for HTTP
// APIs", payload formats 2.0 and 1.0), with the account id replaced by a placeholder and the addresses moved to
// the documentation range.
const sampleV2 = `{
  "version": "2.0",
  "routeKey": "$default",
  "rawPath": "/my/path",
  "rawQueryString": "parameter1=value1&parameter1=value2&parameter2=value",
  "cookies": ["cookie1", "cookie2"],
  "headers": {"header1": "value1", "header2": "value1,value2", "host": "id.execute-api.us-east-1.amazonaws.com"},
  "queryStringParameters": {"parameter1": "value1,value2", "parameter2": "value"},
  "requestContext": {
    "accountId": "ACCOUNT",
    "apiId": "api-id",
    "authentication": {"clientCert": {"clientCertPem": "CERT_CONTENT", "subjectDN": "www.example.com",
      "issuerDN": "Example issuer", "serialNumber": "a1:a1:a1:a1",
      "validity": {"notBefore": "May 28 12:30:02 2019 GMT", "notAfter": "Aug  5 09:36:04 2021 GMT"}}},
    "authorizer": {"jwt": {"claims": {"claim1": "value1", "claim2": "value2"}, "scopes": ["scope1", "scope2"]}},
    "domainName": "id.execute-api.us-east-1.amazonaws.com",
    "domainPrefix": "id",
    "http": {"method": "POST", "path": "/my/path", "protocol": "HTTP/1.1", "sourceIp": "192.0.2.1", "userAgent": "agent"},
    "requestId": "id",
    "routeKey": "$default",
    "stage": "$default",
    "time": "12/Mar/2020:19:03:58 +0000",
    "timeEpoch": 1583348638390
  },
  "body": "Hello from Lambda",
  "pathParameters": {"parameter1": "value1"},
  "isBase64Encoded": false,
  "stageVariables": {"stageVariable1": "value1", "stageVariable2": "value2"}
}`

const sampleV1 = `{
  "version": "1.0",
  "resource": "/my/path",
  "path": "/my/path",
  "httpMethod": "GET",
  "headers": {"header1": "value1", "header2": "value2"},
  "multiValueHeaders": {"header1": ["value1"], "header2": ["value1", "value2"]},
  "queryStringParameters": {"parameter1": "value1", "parameter2": "value"},
  "multiValueQueryStringParameters": {"parameter1": ["value1", "value2"], "parameter2": ["value"]},
  "requestContext": {
    "accountId": "ACCOUNT",
    "apiId": "id",
    "authorizer": {"claims": null, "scopes": null},
    "domainName": "id.execute-api.us-east-1.amazonaws.com",
    "domainPrefix": "id",
    "extendedRequestId": "request-id",
    "httpMethod": "GET",
    "identity": {"accessKey": null, "accountId": null, "caller": null, "cognitoAuthenticationProvider": null,
      "cognitoAuthenticationType": null, "cognitoIdentityId": null, "cognitoIdentityPoolId": null,
      "principalOrgId": null, "sourceIp": "192.0.2.1", "user": null, "userAgent": "user-agent", "userArn": null,
      "clientCert": {"clientCertPem": "CERT_CONTENT", "subjectDN": "www.example.com", "issuerDN": "Example issuer",
        "serialNumber": "a1:a1:a1:a1", "validity": {"notBefore": "May 28 12:30:02 2019 GMT",
        "notAfter": "Aug  5 09:36:04 2021 GMT"}}},
    "path": "/my/path",
    "protocol": "HTTP/1.1",
    "requestId": "id=",
    "requestTime": "04/Mar/2020:19:15:17 +0000",
    "requestTimeEpoch": 1583349317135,
    "resourceId": null,
    "resourcePath": "/my/path",
    "stage": "$default"
  },
  "pathParameters": null,
  "stageVariables": null,
  "body": "Hello from Lambda!",
  "isBase64Encoded": false
}`

// seen is what the handler saw.
type seen struct {
	method, path, rawQuery, host, remote, body string
	header                                     http.Header
	query                                      map[string][]string
	rc                                         *RequestContext
	localAddr                                  any
	marker                                     any
	length                                     int64
}

type marker struct{}

// run sends one event through Handler to a handler that records the request and answers with respond.
func run(t *testing.T, event string, respond func(w http.ResponseWriter)) (seen, map[string]any) {
	t.Helper()
	var s seen
	h := Handler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		s = seen{method: r.Method, path: r.URL.Path, rawQuery: r.URL.RawQuery, host: r.Host, remote: r.RemoteAddr,
			body: string(b), header: r.Header, query: r.URL.Query(), length: r.ContentLength,
			localAddr: r.Context().Value(http.LocalAddrContextKey), marker: r.Context().Value(marker{})}
		s.rc, _ = RequestContextFrom(r.Context())
		if respond != nil {
			respond(w)
		}
	}))
	ctx := context.WithValue(context.Background(), marker{}, "lambda context")
	out, err := h(ctx, []byte(event))
	if err != nil {
		t.Fatal(err)
	}
	var a map[string]any
	if err := json.Unmarshal(out, &a); err != nil {
		t.Fatalf("answer %s: %v", out, err)
	}
	return s, a
}

func TestPayloadV2SampleEvent(t *testing.T) {
	s, a := run(t, sampleV2, func(w http.ResponseWriter) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Add("Set-Cookie", "a=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT")
		w.Header().Add("Set-Cookie", "b=2")
		w.Header().Add("X-Multi", "one")
		w.Header().Add("X-Multi", "two")
		w.WriteHeader(http.StatusCreated)
		io.WriteString(w, `{"ok":true}`)
	})
	if s.method != "POST" || s.path != "/my/path" || s.body != "Hello from Lambda" || s.length != 17 {
		t.Fatalf("request %+v", s)
	}
	if got := s.query["parameter1"]; !reflect.DeepEqual(got, []string{"value1", "value2"}) {
		t.Fatalf("parameter1 %v", got)
	}
	if s.header.Get("Header1") != "value1" || s.header.Get("Header2") != "value1,value2" ||
		s.header.Get("Cookie") != "cookie1; cookie2" {
		t.Fatalf("headers %v", s.header)
	}
	if s.host != "id.execute-api.us-east-1.amazonaws.com" || s.remote != "192.0.2.1" {
		t.Fatalf("host %q remote %q", s.host, s.remote)
	}
	// no listener: the request carries no local address, so no localhost protection can apply to it
	if s.localAddr != nil {
		t.Fatalf("the request carries a local address %v", s.localAddr)
	}
	if s.marker != "lambda context" {
		t.Fatal("the request's context is not the invocation's")
	}
	rc := s.rc
	if rc == nil || rc.PayloadVersion != "2.0" || rc.RequestID != "id" || rc.SourceIP != "192.0.2.1" ||
		rc.Authorizer.Claims["claim1"] != "value1" || !reflect.DeepEqual(rc.Authorizer.Scopes, []string{"scope1", "scope2"}) {
		t.Fatalf("request context %+v", rc)
	}
	if a["statusCode"] != 201.0 || a["body"] != `{"ok":true}` || a["isBase64Encoded"] != false {
		t.Fatalf("answer %v", a)
	}
	hdr := a["headers"].(map[string]any)
	if hdr["X-Multi"] != "one,two" || hdr["Content-Type"] != "application/json" || hdr["Set-Cookie"] != nil {
		t.Fatalf("answer headers %v", hdr)
	}
	if c := a["cookies"].([]any); len(c) != 2 || c[0] != "a=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT" {
		t.Fatalf("answer cookies %v", c)
	}
}

func TestPayloadV1SampleEvent(t *testing.T) {
	for _, event := range []string{sampleV1, strings.Replace(sampleV1, `"version": "1.0",`, "", 1)} {
		s, a := run(t, event, func(w http.ResponseWriter) {
			w.Header().Add("Set-Cookie", "a=1")
			w.Header().Add("Set-Cookie", "b=2")
			w.Header().Set("Content-Type", "text/plain")
			io.WriteString(w, "hi")
		})
		if s.method != "GET" || s.path != "/my/path" || s.body != "Hello from Lambda!" || s.remote != "192.0.2.1" {
			t.Fatalf("request %+v", s)
		}
		if got := s.header.Values("Header2"); !reflect.DeepEqual(got, []string{"value1", "value2"}) {
			t.Fatalf("header2 %v: the multi-value headers are the source", got)
		}
		if got := s.query["parameter1"]; !reflect.DeepEqual(got, []string{"value1", "value2"}) {
			t.Fatalf("parameter1 %v", got)
		}
		rc := s.rc
		if rc == nil || rc.PayloadVersion != "1.0" || rc.RouteKey != "/my/path" || rc.Authorizer.Claims != nil ||
			rc.Authorizer.IAM != nil {
			t.Fatalf("request context %+v", rc)
		}
		if a["statusCode"] != 200.0 || a["body"] != "hi" {
			t.Fatalf("answer %v", a)
		}
		mv := a["multiValueHeaders"].(map[string]any)
		if c := mv["Set-Cookie"].([]any); len(c) != 2 || c[1] != "b=2" {
			t.Fatalf("answer headers %v", mv)
		}
	}
}

func TestBase64BodiesBothWays(t *testing.T) {
	raw := []byte{0x00, 0xff, 0x1f, 0x8b, 'x'}
	event := strings.NewReplacer(`"body": "Hello from Lambda"`, `"body": "`+base64.StdEncoding.EncodeToString(raw)+`"`,
		`"isBase64Encoded": false`, `"isBase64Encoded": true`).Replace(sampleV2)
	s, a := run(t, event, func(w http.ResponseWriter) {
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Write(raw)
	})
	if s.body != string(raw) || s.length != int64(len(raw)) {
		t.Fatalf("decoded body %q", s.body)
	}
	if a["isBase64Encoded"] != true || a["body"] != base64.StdEncoding.EncodeToString(raw) {
		t.Fatalf("answer %v", a)
	}
	// text that is not valid UTF-8 is binary too
	_, a = run(t, sampleV2, func(w http.ResponseWriter) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte{'"', 0xff, '"'})
	})
	if a["isBase64Encoded"] != true {
		t.Fatalf("invalid UTF-8 answered as text: %v", a)
	}
	// a body marked base64 that is not is the client's fault: 400, not a failed invocation
	bad := strings.NewReplacer(`"isBase64Encoded": false`, `"isBase64Encoded": true`,
		`"body": "Hello from Lambda"`, `"body": "%%%"`).Replace(sampleV2)
	out, err := Handler(http.NotFoundHandler())(context.Background(), []byte(bad))
	if err != nil || !bytes.Contains(out, []byte(`"statusCode":400`)) {
		t.Fatalf("bad base64: %s %v", out, err)
	}
}

func TestHeaderCaseIsCanonical(t *testing.T) {
	event := strings.Replace(sampleV1,
		`"multiValueHeaders": {"header1": ["value1"], "header2": ["value1", "value2"]}`,
		`"multiValueHeaders": {"content-type": ["application/json"], "MCP-PROTOCOL-VERSION": ["2026-07-28"], "Mcp-Method": ["tools/call"], "mcp-method": ["tools/list"]}`, 1)
	s, _ := run(t, event, nil)
	if s.header.Get("Content-Type") != "application/json" || s.header.Get("Mcp-Protocol-Version") != "2026-07-28" {
		t.Fatalf("headers %v", s.header)
	}
	if got := s.header.Values("Mcp-Method"); len(got) != 2 {
		t.Fatalf("Mcp-Method %v: both spellings are one header", got)
	}
}

func TestNamedStageAndEscapedQuery(t *testing.T) {
	event := strings.NewReplacer(`"rawPath": "/my/path"`, `"rawPath": "/prod/mcp"`, `"stage": "$default"`, `"stage": "prod"`,
		`"rawQueryString": "parameter1=value1&parameter1=value2&parameter2=value"`, `"rawQueryString": "q=a%20b&r=%2F"`).Replace(sampleV2)
	s, _ := run(t, event, nil)
	if s.path != "/mcp" || s.query["q"][0] != "a b" || s.query["r"][0] != "/" {
		t.Fatalf("path %q query %v", s.path, s.query)
	}
}

func TestAuthorizerContexts(t *testing.T) {
	lambdaV2 := strings.Replace(sampleV2,
		`"authorizer": {"jwt": {"claims": {"claim1": "value1", "claim2": "value2"}, "scopes": ["scope1", "scope2"]}}`,
		`"authorizer": {"lambda": {"repo": "shop", "scopes": 2, "readonly": true, "none": null}}`, 1)
	s, _ := run(t, lambdaV2, nil)
	if want := map[string]string{"repo": "shop", "scopes": "2", "readonly": "true"}; !reflect.DeepEqual(s.rc.Authorizer.Context, want) {
		t.Fatalf("lambda context %v", s.rc.Authorizer.Context)
	}
	iamV2 := strings.Replace(sampleV2,
		`"authorizer": {"jwt": {"claims": {"claim1": "value1", "claim2": "value2"}, "scopes": ["scope1", "scope2"]}}`,
		`"authorizer": {"iam": {"accessKey": "KEY", "accountId": "ACCOUNT", "callerId": "CALLER", "cognitoIdentity": null, "principalOrgId": null, "userArn": "arn:aws:iam::ACCOUNT:user/ci", "userId": "USERID"}}`, 1)
	s, _ = run(t, iamV2, nil)
	if iam := s.rc.Authorizer.IAM; iam == nil || iam.UserARN != "arn:aws:iam::ACCOUNT:user/ci" || iam.CallerID != "CALLER" {
		t.Fatalf("iam %+v", s.rc.Authorizer.IAM)
	}
	cognitoV1 := strings.Replace(sampleV1, `"authorizer": {"claims": null, "scopes": null}`,
		`"authorizer": {"claims": {"sub": "user-1", "client_id": "client-a", "token_use": "access", "scope": "rhobound:read rhobound:fit"}}`, 1)
	s, _ = run(t, cognitoV1, nil)
	if a := s.rc.Authorizer; a.Claims["client_id"] != "client-a" || !reflect.DeepEqual(a.Scopes, []string{"rhobound:read", "rhobound:fit"}) ||
		a.NotStrings != nil {
		t.Fatalf("cognito authorizer %+v", a)
	}
	// claims that are not strings are named, in both payload versions (the rule that names a caller refuses them)
	numV1 := strings.Replace(sampleV1, `"authorizer": {"claims": null, "scopes": null}`,
		`"authorizer": {"claims": {"sub": 123, "client_id": "client-a", "exp": 1700000000, "none": null}}`, 1)
	s, _ = run(t, numV1, nil)
	if a := s.rc.Authorizer; a.Claims["sub"] != "123" || !reflect.DeepEqual(a.NotStrings, []string{"exp", "sub"}) {
		t.Fatalf("claims that are not strings, 1.0: %+v", a)
	}
	numV2 := strings.Replace(sampleV2, `"claims": {"claim1": "value1", "claim2": "value2"}`,
		`"claims": {"sub": {"id": 1}, "client_id": ["a"], "scope": "rhobound:read"}`, 1)
	s, _ = run(t, numV2, nil)
	if a := s.rc.Authorizer; !reflect.DeepEqual(a.NotStrings, []string{"client_id", "sub"}) {
		t.Fatalf("claims that are not strings, 2.0: %+v", a)
	}
	lambdaV1 := strings.Replace(sampleV1, `"authorizer": {"claims": null, "scopes": null}`,
		`"authorizer": {"principalId": "repo-shop", "integrationLatency": 0, "scope": "rhobound:read"}`, 1)
	s, _ = run(t, lambdaV1, nil)
	if a := s.rc.Authorizer; a.PrincipalID != "repo-shop" || a.Context["integrationLatency"] != "0" || a.Context["scope"] != "rhobound:read" {
		t.Fatalf("lambda authorizer %+v", a)
	}
}

func TestDefaultsAndLimits(t *testing.T) {
	// a handler that writes nothing answers 200 with an empty body
	_, a := run(t, sampleV2, nil)
	if a["statusCode"] != 200.0 || a["body"] != "" {
		t.Fatalf("answer %v", a)
	}
	_, a = run(t, sampleV2, func(w http.ResponseWriter) {
		w.Header().Set("Content-Type", "text/plain")
		w.Write(bytes.Repeat([]byte("x"), MaxResponseBytes+1))
	})
	if a["statusCode"] != 502.0 {
		t.Fatalf("an answer over Lambda's limit: status %v", a["statusCode"])
	}
	for _, bad := range []string{`not json`, `{"version":"2.0","requestContext":{}}`, `{"Records":[]}`, `{"version":"3.0","httpMethod":"GET"}`} {
		if _, err := Handler(http.NotFoundHandler())(context.Background(), []byte(bad)); err == nil {
			t.Errorf("%s: accepted as an API Gateway event", bad)
		}
	}
}
