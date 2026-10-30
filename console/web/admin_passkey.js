'use strict';
// The verifier remains on the private server. No secret or CDN script here.
window.pandaPayAdminPasskey = async (encoded, register) => {
  if (location.origin !== 'https://localhost:8443' || !window.isSecureContext ||
      !window.SimpleWebAuthnBrowser) throw new Error('Open the installed local admin console.');
  const optionsJSON = JSON.parse(encoded);
  const credential = register
    ? await SimpleWebAuthnBrowser.startRegistration({optionsJSON})
    : await SimpleWebAuthnBrowser.startAuthentication({optionsJSON});
  return JSON.stringify(credential);
};
