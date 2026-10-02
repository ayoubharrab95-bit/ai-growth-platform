const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const {stripTypeScriptTypes}=require('node:module');
const source=fs.readFileSync(require('node:path').join(__dirname,'../supabase/functions/booked-solid-worker/index.ts'),'utf8');
const a=source.slice(source.indexOf('function extractHrefValues('),source.indexOf('function vanityDigit('));
const ctx={URL};vm.createContext(ctx);vm.runInContext(stripTypeScriptTypes(a),ctx);
const root=new URL('https://example.com/');
const cases=[
 ['<link href="/wp-content/plugins/contact-form-7/styles.css"><a href="/contact">Contact</a>','https://example.com/contact'],
 ['<link href="/assets/contact.css">',null],
 ['<a href="/request-quote">Quote</a>','https://example.com/request-quote'],
 ['<a href="/contact.js?ver=1">x</a>',null],
 ['<a href="/book.pdf">x</a>',null],
 ['<a href="/contact.svg">x</a>',null],
 ['<a href="https://other.com/contact">x</a>',null],
 ['<form action="/wp-admin/admin-post.php"></form><a href="/contact-us">Contact</a>','https://example.com/contact-us'],
 ['<a href="/contact-us?type=commercial">Contact</a>','https://example.com/contact-us?type=commercial'],
 ['<form action="/estimate"></form>','https://example.com/estimate'],
 ['<a href="/wp-json/contact/v1">x</a>',null],
];
for(const [html,expected] of cases)assert.equal(ctx.extractContactFormUrl(html,'https://example.com/about',root,true),expected);
assert.equal(ctx.extractContactFormUrl('<form></form>','https://example.com/contact',root,true),'https://example.com/contact');
assert.equal(ctx.contactPageUrl('/contact.css?ver=1',root.toString(),root),null);
assert.equal(ctx.contactPageUrl('mailto:info@example.com',root.toString(),root),null);
assert.equal(ctx.extractContactFormUrl('<link href="/contact.css">','https://example.com/about',root,false),'https://example.com/contact.css');
console.log('15 form guard checks passed; legacy canary control preserved');
