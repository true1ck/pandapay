'use strict';

// Effect-based policy inventory for the current product-admin API. When an
// endpoint is added to any registrar it must be classified here before the
// private app can be constructed.
const definitions = [];
const add = (method, path, permission, freshMfa = false) => definitions.push([method, path, permission, freshMfa]);
const addFamily = (segment, permission = 'catalogue.edit') => {
  add('POST', `/admin/${segment}`, permission);
  add('PUT', `/admin/${segment}/:id`, permission);
  add('DELETE', `/admin/${segment}/:id`, permission);
};
const addSingleFamily = segment => add('PUT', `/admin/${segment}/by-card/:cardProductId`, 'catalogue.edit');

add('GET', '/admin/me', 'reference.read');
add('GET', '/admin/reference/categories', 'reference.read');
add('GET', '/admin/cards', 'catalogue.read');
add('POST', '/admin/issuers', 'catalogue.edit');
add('POST', '/admin/cards', 'catalogue.edit');
add('PUT', '/admin/reward-rules/:id', 'catalogue.edit');
for (const segment of ['cap-rules', 'milestone-rules', 'fee-waiver-rules', 'card-benefits', 'redemption-options']) addFamily(segment);
for (const segment of ['forex-rules', 'fuel-surcharge-rules', 'billing-cycle-rules']) addSingleFamily(segment);
add('GET', '/admin/parser-patterns', 'catalogue.read');
add('POST', '/admin/parser-patterns', 'catalogue.edit');
add('PUT', '/admin/parser-patterns/:id', 'catalogue.edit');
add('DELETE', '/admin/parser-patterns/:id', 'catalogue.edit');
add('POST', '/admin/cards/:id/status', 'catalogue.publish', true);
add('GET', '/admin/card-requests', 'operations.read');
add('POST', '/admin/card-requests/start-scraping', 'scraper.run');
add('GET', '/admin/error-reports', 'support.evidence.read');
add('POST', '/admin/error-reports/:id/approve', 'catalogue.publish', true);
add('POST', '/admin/error-reports/:id/reject', 'review.write');
add('GET', '/admin/alerts', 'operations.read');
add('GET', '/admin/alerts/:id', 'operations.read');
add('POST', '/admin/alerts/:id/decide', 'review.write');
add('POST', '/admin/notifications/broadcast', 'notifications.broadcast', true);
add('GET', '/admin/support-tickets', 'support.evidence.read');
add('POST', '/admin/support-tickets/:id/resolve', 'support.resolve');
add('POST', '/admin/support-tickets/:id/dismiss', 'support.resolve');
add('GET', '/admin/merchants', 'catalogue.read');
add('GET', '/admin/merchants/:id', 'catalogue.read');
add('POST', '/admin/merchants/:id/override', 'catalogue.edit');
add('POST', '/admin/merchants/:id/unpublish', 'catalogue.publish', true);
add('GET', '/admin/merchant-conflicts', 'operations.read');
add('POST', '/admin/merchant-conflicts/:id/resolve', 'catalogue.edit');
add('GET', '/admin/abuse-signals', 'support.evidence.read');
add('POST', '/admin/abuse-signals/:id/block', 'referrals.control', true);
add('GET', '/admin/acceptance-summary', 'catalogue.read');
add('GET', '/admin/acceptance-summary/:merchantId', 'catalogue.read');
add('POST', '/admin/acceptance-summary/publish', 'catalogue.publish', true);
add('GET', '/admin/effective-rate-summary', 'financial.evidence.read');
add('GET', '/admin/effective-rate-summary/:cardProductId/:categoryId/samples', 'financial.evidence.read');
add('GET', '/admin/sources', 'operations.read');
add('POST', '/admin/sources', 'scraper.configure');
add('PATCH', '/admin/sources/:id', 'scraper.configure');
add('GET', '/admin/scrape-runs', 'operations.read');
add('GET', '/admin/source-pages/:id/snapshots', 'operations.read');
add('GET', '/admin/sources/:id/pages', 'operations.read');
add('GET', '/admin/data-quality-dashboard', 'operations.read');
add('GET', '/admin/anonymization-audit-runs', 'admin.audit.read');
add('GET', '/admin/anonymization-audit-runs/latest', 'admin.audit.read');
add('POST', '/admin/anonymization-audit-runs/run', 'admin.audit.run', true);
add('GET', '/admin/referrals/operations', 'referrals.read');
add('PUT', '/admin/referrals/holds/:scope', 'referrals.control', true);
add('GET', '/admin/sms-ai/summary', 'ai.queue.read');
add('GET', '/admin/sms-ai/jobs', 'ai.queue.read');
add('GET', '/admin/sms-ai/jobs/:id/events', 'ai.queue.read');
add('GET', '/admin/sms-ai/quota', 'ai.queue.read');
add('POST', '/admin/sms-ai/dry-run', 'ai.queue.run');
add('GET', '/admin/sms-ai/rollout', 'ai.queue.read');
add('PATCH', '/admin/sms-ai/rollout/:key', 'learning.publish', true);
add('GET', '/admin/sms-learning/operations', 'learning.read');
add('GET', '/admin/sms-learning/candidates', 'learning.read');
add('GET', '/admin/sms-learning/rule-negative-evidence', 'learning.read');
add('GET', '/admin/sms-learning/feedback-events', 'learning.read');
add('POST', '/admin/sms-learning/feedback-events/:eventId/review', 'review.write');
add('POST', '/admin/sms-learning/candidates/:id/decision', 'learning.publish', true);
add('POST', '/admin/sms-learning/candidates/:id/pause', 'learning.publish', true);
add('POST', '/admin/sms-learning/candidates/:id/resume', 'learning.publish', true);
add('GET', '/admin/sms-learning/ai-proposals', 'learning.read');
add('POST', '/admin/sms-learning/ai-proposals/review', 'learning.publish', true);
add('GET', '/admin/sms-rules/category-proposals', 'learning.read');
add('POST', '/admin/sms-rules/category-proposals/review', 'learning.publish', true);
add('GET', '/admin/sms-rules/parser-proposals', 'learning.read');
add('POST', '/admin/sms-rules/parser-proposals/review', 'learning.publish', true);
add('GET', '/admin/sms-rules/bundles', 'learning.read');
add('GET', '/admin/sms-rules/bundles/:bundleVersion', 'learning.read');
add('POST', '/admin/sms-rules/publish', 'learning.publish', true);
add('POST', '/admin/sms-rules/:bundleVersion/rollback', 'learning.publish', true);
add('POST', '/admin/sms-learning/cycle', 'learning.cycle', true);

const routeManifest = Object.freeze(definitions.map(([method, path, permission, freshMfa]) =>
  Object.freeze({ method, path, permission, freshMfa })
));
const routeKey = (method, path) => `${String(method).toUpperCase()} ${path}`;
module.exports = { routeManifest, routeKey };
