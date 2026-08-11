const fs = require('fs');
const content = fs.readFileSync('lib/services/lan_transfer/lan_web.dart', 'utf8');
const start = content.indexOf("r'''") + 4;
const end = content.indexOf("'''", start);
const html = content.slice(start, end);
const s = html.indexOf('<script>') + 8;
const e = html.indexOf('</script>');
const js = html.slice(s, e);
try {
  new Function(js);
  console.log('JS syntax OK, length=' + js.length);
} catch (err) {
  console.error('JS SYNTAX ERROR:', err.message);
  process.exit(1);
}
