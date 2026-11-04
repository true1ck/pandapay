'use strict';
const {createHash}=require('node:crypto');
const {fail,matches}=require('./validation');
const MAX_COMMAND_BYTES=65536;

function validUnicode(value) {
  for(let i=0;i<value.length;i++) {
    const unit=value.charCodeAt(i);
    if(unit>=0xd800 && unit<=0xdbff) {
      const next=value.charCodeAt(++i);
      if(!(next>=0xdc00 && next<=0xdfff))return false;
    } else if(unit>=0xdc00 && unit<=0xdfff)return false;
  }
  return true;
}

// Restricted JSON canonicalization, shared with the local immutable-command
// queue. Financial values are strings; numeric scalars must be safe integers.
function canonicalJson(value) {
  let bytes=0,nodes=0;
  const ancestors=new Set(),parts=[];
  function append(text) {
    bytes+=Buffer.byteLength(text,'utf8');
    if(bytes>MAX_COMMAND_BYTES)fail('PAYLOAD_TOO_LARGE','$');
    parts.push(text);
  }
  function visit(input,depth) {
    if(depth>16 || ++nodes>8192)fail('INVALID_INPUT','$');
    if(input===null) {append('null');return;}
    if(typeof input==='boolean') {append(input?'true':'false');return;}
    if(typeof input==='number') {
      if(!Number.isSafeInteger(input)||Object.is(input,-0))fail('INVALID_INPUT','$');
      append(String(input));return;
    }
    if(typeof input==='string') {
      if(input.length>MAX_COMMAND_BYTES)fail('PAYLOAD_TOO_LARGE','$');
      if(!validUnicode(input))fail('INVALID_INPUT','$');
      append(JSON.stringify(input));return;
    }
    if(typeof input!=='object'||ancestors.has(input)||Object.getOwnPropertySymbols(input).length)fail('INVALID_INPUT','$');
    ancestors.add(input);
    if(Array.isArray(input)) {
      if(input.length>1000 || Object.keys(input).length!==input.length)fail('INVALID_INPUT','$');
      append('[');
      for(let i=0;i<input.length;i++) {
        const descriptor=Object.getOwnPropertyDescriptor(input,String(i));
        if(!descriptor||!Object.hasOwn(descriptor,'value'))fail('INVALID_INPUT','$');
        if(i)append(',');visit(descriptor.value,depth+1);
      }
      append(']');
    } else {
      if(![Object.prototype,null].includes(Object.getPrototypeOf(input))||Object.getOwnPropertySymbols(input).length)fail('INVALID_INPUT','$');
      const keys=Object.keys(input).sort();
      if(keys.length>128)fail('INVALID_INPUT','$');
      append('{');
      for(let i=0;i<keys.length;i++) {
        const key=keys[i],descriptor=Object.getOwnPropertyDescriptor(input,key);
        if(key.length>128||!matches(/^[A-Za-z][A-Za-z0-9_]*$/,key)||!Object.hasOwn(descriptor,'value'))fail('INVALID_INPUT','$');
        if(i)append(',');append(JSON.stringify(key));append(':');visit(descriptor.value,depth+1);
      }
      append('}');
    }
    ancestors.delete(input);
  }
  visit(value,0);
  return parts.join('');
}
function commandHash(value) {return createHash('sha256').update(canonicalJson(value),'utf8').digest('hex');}
module.exports={MAX_COMMAND_BYTES,canonicalJson,commandHash,validUnicode};
