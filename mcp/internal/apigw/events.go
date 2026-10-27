// SPDX-License-Identifier: Apache-2.0

package apigw

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"sort"
	"strings"
)

// eventV2 is the HTTP API payload format 2.0. Headers arrive lower-cased, with repeated headers joined by
// commas; cookies arrive apart, in cookies[].
type eventV2 struct {
	RawPath         string            `json:"rawPath"`
	RawQueryString  string            `json:"rawQueryString"`
	Cookies         []string          `json:"cookies"`
	Headers         map[string]string `json:"headers"`
	Body            string            `json:"body"`
	IsBase64Encoded bool              `json:"isBase64Encoded"`
	RouteKey        string            `json:"routeKey"`
	RequestContext  struct {
		RequestID  string `json:"requestId"`
		APIID      string `json:"apiId"`
		Stage      string `json:"stage"`
		DomainName string `json:"domainName"`
		HTTP       struct {
			Method   string `json:"method"`
			Path     string `json:"path"`
			SourceIP string `json:"sourceIp"`
		} `json:"http"`
		Authorizer *struct {
			JWT *struct {
				Claims map[string]json.RawMessage `json:"claims"`
				Scopes []string                   `json:"scopes"`
			} `json:"jwt"`
			Lambda map[string]json.RawMessage `json:"lambda"`
			IAM    *iamV2                     `json:"iam"`
		} `json:"authorizer"`
	} `json:"requestContext"`
}

type iamV2 struct {
	AccountID      *string `json:"accountId"`
	CallerID       *string `json:"callerId"`
	UserARN        *string `json:"userArn"`
	UserID         *string `json:"userId"`
	PrincipalOrgID *string `json:"principalOrgId"`
}

func str(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func (e *eventV2) request(ctx context.Context) (*http.Request, *RequestContext, error) {
	c := &e.RequestContext
	path := e.RawPath
	if path == "" {
		path = c.HTTP.Path
	}
	// with a named stage (not $default), the path starts with the stage's name; routes do not
	if c.Stage != "" && c.Stage != "$default" && strings.HasPrefix(path, "/"+c.Stage+"/") {
		path = path[len(c.Stage)+1:]
	}
	req, err := newRequest(ctx, c.HTTP.Method, path, e.RawQueryString, e.Body, e.IsBase64Encoded)
	if err != nil {
		return nil, nil, err
	}
	// a repeated header arrives joined by commas, which is how a client sends a list in one header line; it is
	// kept as one value
	for _, k := range sortedKeys(e.Headers) {
		req.Header.Add(k, e.Headers[k])
	}
	if len(e.Cookies) > 0 {
		req.Header.Set("Cookie", strings.Join(e.Cookies, "; "))
	}
	finish(req, c.DomainName, c.HTTP.SourceIP)
	rc := &RequestContext{PayloadVersion: "2.0", RequestID: c.RequestID, APIID: c.APIID, Stage: c.Stage,
		DomainName: c.DomainName, RouteKey: e.RouteKey, SourceIP: c.HTTP.SourceIP}
	if a := c.Authorizer; a != nil {
		if a.JWT != nil {
			rc.Authorizer.Claims, rc.Authorizer.NotStrings = stringMap(a.JWT.Claims), notStrings(a.JWT.Claims)
			rc.Authorizer.Scopes = a.JWT.Scopes
		}
		rc.Authorizer.Context = stringMap(a.Lambda)
		if a.IAM != nil {
			rc.Authorizer.IAM = &IAMCaller{AccountID: str(a.IAM.AccountID), CallerID: str(a.IAM.CallerID),
				UserARN: str(a.IAM.UserARN), UserID: str(a.IAM.UserID), PrincipalOrgID: str(a.IAM.PrincipalOrgID)}
		}
	}
	return req, rc, nil
}

type answer2 struct {
	StatusCode      int               `json:"statusCode"`
	Headers         map[string]string `json:"headers,omitempty"`
	Cookies         []string          `json:"cookies,omitempty"`
	Body            string            `json:"body"`
	IsBase64Encoded bool              `json:"isBase64Encoded"`
}

// answerV2 writes the 2.0 answer: repeated headers joined by commas, except Set-Cookie, which goes to cookies[]
// (a comma inside an Expires date would split it otherwise).
func answerV2(w *recorder) ([]byte, error) {
	a := answer2{StatusCode: w.statusCode(), Headers: map[string]string{}}
	for k, vs := range w.header {
		if k == "Set-Cookie" {
			a.Cookies = append(a.Cookies, vs...)
			continue
		}
		a.Headers[k] = strings.Join(vs, ",")
	}
	a.Body, a.IsBase64Encoded = w.encodeBody()
	b, err := json.Marshal(a)
	if err == nil && len(b) > MaxResponseBytes {
		return answerV2(tooLarge())
	}
	return b, err
}

// eventV1 is the REST API proxy payload (format 1.0, also an HTTP API option). Headers keep the client's case;
// repeated headers and query parameters come in the multi-value maps.
type eventV1 struct {
	Resource                        string              `json:"resource"`
	Path                            string              `json:"path"`
	HTTPMethod                      string              `json:"httpMethod"`
	Headers                         map[string]string   `json:"headers"`
	MultiValueHeaders               map[string][]string `json:"multiValueHeaders"`
	QueryStringParameters           map[string]string   `json:"queryStringParameters"`
	MultiValueQueryStringParameters map[string][]string `json:"multiValueQueryStringParameters"`
	Body                            *string             `json:"body"`
	IsBase64Encoded                 bool                `json:"isBase64Encoded"`
	RequestContext                  struct {
		RequestID  string                     `json:"requestId"`
		APIID      string                     `json:"apiId"`
		Stage      string                     `json:"stage"`
		DomainName string                     `json:"domainName"`
		Authorizer map[string]json.RawMessage `json:"authorizer"`
		Identity   struct {
			SourceIP       *string `json:"sourceIp"`
			AccountID      *string `json:"accountId"`
			Caller         *string `json:"caller"`
			UserARN        *string `json:"userArn"`
			User           *string `json:"user"`
			PrincipalOrgID *string `json:"principalOrgId"`
		} `json:"identity"`
	} `json:"requestContext"`
}

func (e *eventV1) request(ctx context.Context) (*http.Request, *RequestContext, error) {
	q := url.Values{}
	if len(e.MultiValueQueryStringParameters) > 0 {
		for k, vs := range e.MultiValueQueryStringParameters {
			for _, v := range vs {
				q.Add(k, v)
			}
		}
	} else {
		for k, v := range e.QueryStringParameters {
			q.Set(k, v)
		}
	}
	body := ""
	if e.Body != nil {
		body = *e.Body
	}
	req, err := newRequest(ctx, e.HTTPMethod, e.Path, q.Encode(), body, e.IsBase64Encoded)
	if err != nil {
		return nil, nil, err
	}
	if len(e.MultiValueHeaders) > 0 {
		for _, k := range sortedKeys(e.MultiValueHeaders) {
			for _, v := range e.MultiValueHeaders[k] {
				req.Header.Add(k, v)
			}
		}
	} else {
		for _, k := range sortedKeys(e.Headers) {
			req.Header.Add(k, e.Headers[k])
		}
	}
	c := &e.RequestContext
	src := str(c.Identity.SourceIP)
	finish(req, c.DomainName, src)
	rc := &RequestContext{PayloadVersion: "1.0", RequestID: c.RequestID, APIID: c.APIID, Stage: c.Stage,
		DomainName: c.DomainName, RouteKey: e.Resource, SourceIP: src}
	if a := c.Authorizer; len(a) > 0 {
		var claims map[string]json.RawMessage
		if raw, ok := a["claims"]; ok {
			json.Unmarshal(raw, &claims)
		}
		rc.Authorizer.Claims, rc.Authorizer.NotStrings = stringMap(claims), notStrings(claims)
		if s := rc.Authorizer.Claims["scope"]; s != "" {
			rc.Authorizer.Scopes = strings.Fields(s)
		}
		rest := map[string]json.RawMessage{}
		for k, v := range a {
			switch k {
			case "claims", "scopes":
			case "principalId":
				json.Unmarshal(v, &rc.Authorizer.PrincipalID)
			default:
				rest[k] = v
			}
		}
		rc.Authorizer.Context = stringMap(rest)
	}
	if id := c.Identity; id.UserARN != nil || id.Caller != nil {
		rc.Authorizer.IAM = &IAMCaller{AccountID: str(id.AccountID), CallerID: str(id.Caller),
			UserARN: str(id.UserARN), UserID: str(id.User), PrincipalOrgID: str(id.PrincipalOrgID)}
	}
	return req, rc, nil
}

type answer1 struct {
	StatusCode        int                 `json:"statusCode"`
	MultiValueHeaders map[string][]string `json:"multiValueHeaders,omitempty"`
	Body              string              `json:"body"`
	IsBase64Encoded   bool                `json:"isBase64Encoded"`
}

// answerV1 writes the 1.0 answer with every header in multiValueHeaders, Set-Cookie included.
func answerV1(w *recorder) ([]byte, error) {
	a := answer1{StatusCode: w.statusCode()}
	if len(w.header) > 0 {
		a.MultiValueHeaders = map[string][]string(w.header.Clone())
	}
	a.Body, a.IsBase64Encoded = w.encodeBody()
	b, err := json.Marshal(a)
	if err == nil && len(b) > MaxResponseBytes {
		return answerV1(tooLarge())
	}
	return b, err
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
