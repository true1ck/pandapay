'use strict';
function denyPublicAdmin(req,res,next) {
  let path=(req.originalUrl||req.url||'').split('?')[0];
  try {path=decodeURIComponent(path);}catch{return res.status(400).json({error:'invalid_path'});}
  path=path.replace(/\\/g,'/').replace(/\/{2,}/g,'/').toLowerCase();
  if(/^\/(?:admin|browser)(?:\/|$)/.test(path)||/^\/internal\/admin(?:\/|$)/.test(path))return res.status(404).json({error:'not_found'});
  return next();
}
module.exports={denyPublicAdmin};
