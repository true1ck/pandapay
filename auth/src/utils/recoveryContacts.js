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

module.exports = { maskEmail, maskPhone };
