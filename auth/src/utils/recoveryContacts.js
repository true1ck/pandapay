function maskEmail(email) {
  if (!email || !email.includes('@')) return null;
  const [local, domain] = email.split('@');
  return `${local.slice(0, 1)}•••@${domain}`;
}

function maskPhone(phone) {
  if (!phone) return null;
  const digits = String(phone).replace(/\D/g, '');
  if (digits.length < 4) return '••••';
  const country = String(phone).startsWith('+') && digits.length > 10
    ? `+${digits.slice(0, -10)} ` : '';
  return `${country}•••• ${digits.slice(-4)}`;
}

function maskPhonePrefix(phone) {
  if (!phone) return null;
  const digits = String(phone).replace(/\D/g, '');
  if (digits.length < 4) return '••••';
  if (String(phone).startsWith('+') && digits.length > 10) {
    const country = digits.slice(0, -10);
    const national = digits.slice(-10);
    const dots = '•'.repeat(Math.max(2, national.length - 2));
    return `+${country} ${national.slice(0, 2)}${dots}`;
  }
  const dots = '•'.repeat(Math.max(2, digits.length - 2));
  return `${digits.slice(0, 2)}${dots}`;
}

module.exports = { maskEmail, maskPhone, maskPhonePrefix };
