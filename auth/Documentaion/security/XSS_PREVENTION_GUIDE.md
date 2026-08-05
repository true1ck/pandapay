# XSS Prevention Guide

## Overview

Cross-Site Scripting (XSS) is a security vulnerability that allows attackers to inject malicious scripts into web pages viewed by other users. This guide provides best practices for preventing XSS attacks in frontend applications that interact with the Farm Auth Service.

## Server-Side Protection

The Farm Auth Service implements several server-side protections:

### 1. Content Security Policy (CSP)

The service sets a strict Content Security Policy header that:
- Restricts script execution to same-origin and nonce-based inline scripts
- Prevents unauthorized resource loading
- Blocks inline event handlers and `javascript:` URLs

**CSP Header Example:**
```
Content-Security-Policy: default-src 'self'; script-src 'self' 'nonce-...' 'unsafe-eval'; style-src 'self' 'nonce-...'; ...
```

### 2. Security Headers

Additional security headers are set:
- `X-XSS-Protection: 1; mode=block` - Legacy browser XSS filter
- `X-Content-Type-Options: nosniff` - Prevents MIME type sniffing
- `X-Frame-Options: DENY` - Prevents clickjacking

### 3. CORS Protection

Strict CORS origin whitelisting prevents unauthorized domains from making requests.

## Frontend Best Practices

### 1. Output Encoding

**Always encode user input before displaying it:**

```javascript
// ❌ BAD - Vulnerable to XSS
document.getElementById('username').innerHTML = userInput;

// ✅ GOOD - Safe
document.getElementById('username').textContent = userInput;
```

**For HTML content, use proper encoding:**
```javascript
function escapeHtml(text) {
  const map = {
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#039;'
  };
  return text.replace(/[&<>"']/g, m => map[m]);
}

// Use when you must set innerHTML
element.innerHTML = escapeHtml(userInput);
```

### 2. Avoid Dangerous APIs

**Never use these with user input:**
- `innerHTML`
- `outerHTML`
- `document.write()`
- `eval()`
- `Function()` constructor
- `setTimeout()` / `setInterval()` with string arguments

**Use safe alternatives:**
- `textContent` instead of `innerHTML`
- `setAttribute()` for attributes
- `addEventListener()` instead of inline event handlers

### 3. Content Security Policy Nonce Support

If you need inline scripts or styles, use CSP nonces:

```javascript
// Get nonce from meta tag (if server sets it)
const nonce = document.querySelector('meta[name="csp-nonce"]')?.content;

// Use nonce in script tag
const script = document.createElement('script');
script.nonce = nonce;
script.textContent = '// Your inline script';
document.head.appendChild(script);
```

**Note:** The current CSP configuration allows `'unsafe-inline'` for compatibility, but this should be tightened in production by using nonces exclusively.

### 4. Sanitize User Input

**For rich text content, use a sanitization library:**

```javascript
// Using DOMPurify (recommended)
import DOMPurify from 'dompurify';

const clean = DOMPurify.sanitize(userInput, {
  ALLOWED_TAGS: ['b', 'i', 'em', 'strong', 'a', 'p'],
  ALLOWED_ATTR: ['href']
});

element.innerHTML = clean;
```

### 5. URL Validation

**Always validate and sanitize URLs:**

```javascript
function isValidUrl(url) {
  try {
    const parsed = new URL(url);
    // Only allow http/https
    return parsed.protocol === 'http:' || parsed.protocol === 'https:';
  } catch {
    return false;
  }
}

// Use for links
if (isValidUrl(userUrl)) {
  link.href = userUrl;
} else {
  link.href = '#';
  link.onclick = (e) => { e.preventDefault(); alert('Invalid URL'); };
}
```

### 6. JSON Handling

**Always parse JSON safely:**

```javascript
// ❌ BAD - eval() is dangerous
const data = eval('(' + jsonString + ')');

// ✅ GOOD - Use JSON.parse()
try {
  const data = JSON.parse(jsonString);
} catch (e) {
  console.error('Invalid JSON');
}
```

### 7. React / Vue / Angular Specific

**React:**
- React automatically escapes content in JSX
- Use `dangerouslySetInnerHTML` only when necessary and sanitize first
- Never use `dangerouslySetInnerHTML` with user input

```jsx
// ✅ GOOD - React escapes automatically
<div>{userInput}</div>

// ⚠️ CAUTION - Only if absolutely necessary
<div dangerouslySetInnerHTML={{ __html: DOMPurify.sanitize(userInput) }} />
```

**Vue:**
- Use `v-text` instead of `v-html` when possible
- Sanitize before using `v-html`

```vue
<!-- ✅ GOOD -->
<div v-text="userInput"></div>

<!-- ⚠️ CAUTION - Sanitize first -->
<div v-html="sanitizedInput"></div>
```

**Angular:**
- Use interpolation `{{ }}` which automatically escapes
- Use `[innerHTML]` only with sanitized content

```typescript
// ✅ GOOD - Angular escapes automatically
<div>{{ userInput }}</div>

// ⚠️ CAUTION - Use DomSanitizer
import { DomSanitizer } from '@angular/platform-browser';
const safe = this.sanitizer.sanitize(SecurityContext.HTML, userInput);
```

### 8. API Response Handling

**Never trust API responses blindly:**

```javascript
// ❌ BAD - Directly inserting API response
fetch('/api/user')
  .then(r => r.json())
  .then(data => {
    document.getElementById('profile').innerHTML = data.bio; // DANGEROUS!
  });

// ✅ GOOD - Sanitize or use textContent
fetch('/api/user')
  .then(r => r.json())
  .then(data => {
    document.getElementById('profile').textContent = data.bio; // Safe
  });
```

### 9. Cookie Security

**Set secure cookie flags (server-side):**
- `HttpOnly` - Prevents JavaScript access
- `Secure` - Only sent over HTTPS
- `SameSite=Strict` - Prevents CSRF

**Note:** The Farm Auth Service uses Bearer tokens, not cookies, which is more secure.

### 10. Third-Party Libraries

**Be cautious with third-party libraries:**
- Only use well-maintained, trusted libraries
- Keep dependencies updated
- Review library code for XSS vulnerabilities
- Use Content Security Policy to restrict external scripts

## Testing for XSS

### Manual Testing

Try these payloads in input fields:

```html
<script>alert('XSS')</script>
<img src=x onerror=alert('XSS')>
<svg onload=alert('XSS')>
javascript:alert('XSS')
<iframe src="javascript:alert('XSS')">
```

### Automated Testing

Use tools like:
- OWASP ZAP
- Burp Suite
- XSSer
- Browser DevTools Console

## Common XSS Attack Vectors

1. **Stored XSS:** Malicious script stored in database and executed when displayed
2. **Reflected XSS:** Malicious script in URL parameters reflected in response
3. **DOM-based XSS:** Malicious script in DOM manipulation without server interaction

## Checklist

- [ ] All user input is encoded before display
- [ ] No use of `innerHTML` with user input
- [ ] URLs are validated before use
- [ ] JSON is parsed safely (not with `eval()`)
- [ ] Third-party libraries are vetted and updated
- [ ] CSP nonces are used for inline scripts/styles
- [ ] API responses are sanitized
- [ ] Framework-specific best practices are followed
- [ ] Regular security audits are performed

## Additional Resources

- [OWASP XSS Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Cross_Site_Scripting_Prevention_Cheat_Sheet.html)
- [MDN Web Security: XSS](https://developer.mozilla.org/en-US/docs/Web/Security/Types_of_attacks#cross-site_scripting_xss)
- [Content Security Policy Reference](https://developer.mozilla.org/en-US/docs/Web/HTTP/CSP)

## Reporting Security Issues

If you discover an XSS vulnerability in the Farm Auth Service, please report it responsibly:
1. Do not disclose publicly
2. Contact the security team
3. Provide detailed reproduction steps
4. Allow time for fix before disclosure

---

**Last Updated:** 2024
**Version:** 1.0
