# CSRF Protection Notes

## Current Implementation

Currently, this authentication service uses **Bearer tokens** in the `Authorization` header. This approach is **CSRF-safe** because:

1. **Same-Origin Policy**: Browsers enforce same-origin policy for JavaScript requests
2. **Custom Headers**: Bearer tokens in custom headers cannot be set by malicious sites
3. **No Cookies**: We don't store tokens in cookies, so there's no automatic cookie sending

## Future Considerations

### If Moving to HTTP-Only Cookies

If you decide to move tokens to HTTP-only cookies in the future (for XSS protection), **CSRF protection becomes mandatory**. Here's what you should implement:

### Recommended CSRF Protection Strategy

1. **SameSite Cookie Attribute**
   ```javascript
   // Set cookies with SameSite=Strict or SameSite=Lax
   res.cookie('access_token', token, {
     httpOnly: true,
     secure: true, // HTTPS only
     sameSite: 'strict', // or 'lax'
     maxAge: 15 * 60 * 1000 // 15 minutes
   });
   ```

2. **CSRF Token Validation**
   - Issue a CSRF token on login
   - Store CSRF token in a separate cookie (not httpOnly)
   - Require CSRF token in a custom header (e.g., `X-CSRF-Token`) for state-changing requests
   - Validate CSRF token on each request

3. **Double Submit Cookie Pattern**
   - Store CSRF token in both:
     - Cookie (httpOnly: false, so JavaScript can read it)
     - Request header (sent by JavaScript)
   - Validate that both values match

### Implementation Example (if needed)

```javascript
// Middleware to validate CSRF token
function csrfProtection(req, res, next) {
  // Skip for GET, HEAD, OPTIONS (safe methods)
  if (['GET', 'HEAD', 'OPTIONS'].includes(req.method)) {
    return next();
  }

  const csrfToken = req.headers['x-csrf-token'];
  const cookieToken = req.cookies.csrf_token;

  if (!csrfToken || !cookieToken || csrfToken !== cookieToken) {
    return res.status(403).json({ error: 'Invalid CSRF token' });
  }

  next();
}
```

### Additional Recommendations

1. **Origin Header Validation**: Validate the `Origin` header matches your allowed origins
2. **Referer Header Check**: As a fallback, check `Referer` header (though it can be spoofed)
3. **State Parameter**: For OAuth flows, use state parameters to prevent CSRF

## Current Status

✅ **No CSRF protection needed** - Using Bearer tokens in headers is CSRF-safe

⚠️ **If you move to cookies** - Implement CSRF protection immediately

## References

- [OWASP CSRF Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html)
- [MDN: SameSite Cookies](https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Set-Cookie/SameSite)







