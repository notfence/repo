def escaped: @html;

def changelog:
  $releases
  | map(
      "<section class=\"release\">" +
      "<h2>" + (.version | escaped) + "</h2>" +
      "<div class=\"notes\">" +
      (.html | gsub("<a "; "<a target=\"_open\" ")) +
      "</div>" +
      "</section>"
    )
  | join("");

"<!doctype html>\n" +
"<html lang=\"en\">\n" +
"<head>\n" +
"<meta charset=\"utf-8\">\n" +
"<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n" +
"<title>" + ($name | escaped) + "</title>\n" +
"<style>" +
"body{margin:0;padding:16px;font-family:-apple-system,Helvetica,Arial,sans-serif;background:#fff;color:#111;line-height:1.45}" +
".header{min-height:72px}.header img{float:left;width:64px;height:64px;margin:0 12px 8px 0;border-radius:12px}" +
"h1{font-size:24px;margin:0;padding-top:17px}.clear{clear:both}" +
"p{font-size:16px}.button{display:block;margin:18px 0;padding:12px;text-align:center;color:#fff;background:#1769e0;border-radius:9px;text-decoration:none;font-weight:bold}" +
"h2{font-size:18px;margin:20px 0 6px}.release{border-top:1px solid #ddd}" +
".notes h1,.notes h2,.notes h3{font-size:16px;margin:12px 0 6px}.notes ul{margin:6px 0;padding-left:24px}.notes p{font-size:14px}.notes code{word-wrap:break-word}" +
"@media(prefers-color-scheme:dark){body{background:#111;color:#eee}.release{border-color:#333}}" +
"</style>\n" +
"</head>\n" +
"<body>\n" +
"<div class=\"header\"><img src=\"" + ($icon | escaped) + "\" alt=\"\"><h1>" + ($name | escaped) + "</h1></div>" +
"<div class=\"clear\"></div>" +
"<p>" + ($description | escaped) + "</p>" +
"<a class=\"button\" target=\"_open\" href=\"" + ($homepage | escaped) + "\">View on GitHub</a>" +
"<h1>Changelog</h1>" +
changelog +
"</body>\n" +
"</html>\n"
