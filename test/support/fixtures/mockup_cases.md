# 492 mockup: shared page cases

Each line in a `cases` block is one test: `<verdict> <place> <snippet>`.

- `verdict` is `allowed` or `refused`.
- `place` is `head` or `body`: where the snippet goes in the page below.
- The snippet is the rest of the line, used byte for byte.

The page is the screen `start` of a version whose screens are `start` (title `Start`) and
`next` (title `Next`). `{head}` and `{body}` are replaced by the snippet or by nothing:

```
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Start</title>{head}</head><body>{body}</body></html>
```

The page with both empty is allowed. A test passes when the check refuses the page for a
`refused` line and accepts it for an `allowed` line.

## Elements

```cases
allowed body <div><p>Text</p><span>more</span></div>
allowed body <table><caption>Hours</caption><thead><tr><th scope="col">Day</th></tr></thead><tbody><tr><td colspan="2">Mon</td></tr></tbody></table>
allowed body <details open><summary>More</summary><p>Text</p></details>
allowed body <label for="q">Search</label><input id="q" type="search" placeholder="Find">
allowed body <select name="s"><optgroup label="G"><option value="1" selected>One</option></optgroup></select>
allowed body <svg viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg"><path d="M0 0L10 10" stroke="#333"/></svg>
refused body <script>alert(1)</script>
refused body <SCRIPT>alert(1)</SCRIPT>
refused body <noscript><p>x</p></noscript>
refused body <iframe src="next.html"></iframe>
refused body <object></object>
refused body <embed>
refused body <form><input type="text"></form>
refused body <template><p>x</p></template>
refused body <dialog open>x</dialog>
refused body <video></video>
refused body <audio></audio>
refused body <canvas></canvas>
refused body <math><mi>x</mi></math>
refused body <svg><a href="next.html"><text>x</text></a></svg>
refused body <svg><foreignObject><p>x</p></foreignObject></svg>
refused body <svg><animate attributeName="x"/></svg>
refused body <svg><set attributeName="x"/></svg>
refused body <marquee>x</marquee>
refused head <base href="https://example.com/">
refused head <link rel="stylesheet" href="https://example.com/a.css">
```

## Meta and title

```cases
allowed head <meta name="viewport" content="width=device-width">
refused head <meta http-equiv="refresh" content="0;url=https://example.com/">
refused head <meta http-equiv="Content-Security-Policy" content="default-src *">
refused head <meta name="referrer" content="unsafe-url">
refused head <meta charset="iso-8859-1">
refused head <title>Other</title>
```

The page `<!doctype html><html><head><meta charset="utf-8"></head><body></body></html>`
has no `<title>` and is refused. A page whose `<title>` is ` Start ` with a line feed inside
the spaces is allowed.

## Attributes

```cases
allowed body <div id="a" class="b" style="color:#333" title="t" lang="en" dir="ltr" role="note" aria-label="x" data-to="next" tabindex="0" hidden>x</div>
allowed body <img src="data:image/png;base64,iVBORw0KGgo=" alt="Logo" width="10" height="10">
refused body <div onclick="x()">x</div>
refused body <div OnMouseOver="x()">x</div>
refused body <img src="data:image/png;base64,iVBORw0KGgo=" onerror="x()">
refused body <div srcdoc="x">x</div>
refused body <a href="next.html" target="_blank">Next</a>
refused body <a href="next.html" ping="https://example.com/">Next</a>
refused body <a href="next.html" download>Next</a>
refused body <div background="https://example.com/a.png">x</div>
refused body <img src="data:image/png;base64,iVBORw0KGgo=" usemap="#m">
refused body <button formaction="https://example.com/">Go</button>
```

## Links and addresses

```cases
allowed body <a href="next.html">Next</a>
allowed body <a href="start.html">Start</a>
refused body <a href="missing.html">Gone</a>
refused body <a href="next.html#top">Next</a>
refused body <a href="next.html?x=1">Next</a>
refused body <a href="next .html">Next</a>
allowed body <a href=" next.html ">Next</a>
refused body <img src="d ata:image/png;base64,AA" alt="x">
refused body <a href="https://example.com/">Out</a>
refused body <a href="//example.com/">Out</a>
refused body <a href="#top">Top</a>
refused body <a href="javascript:alert(1)">x</a>
refused body <a href="JaVaScRiPt:alert(1)">x</a>
refused body <a href="&#106;avascript:alert(1)">x</a>
refused body <a href="&#x6A;avascript:alert(1)">x</a>
refused body <a href="java&#09;script:alert(1)">x</a>
refused body <a href=" javascript:alert(1)">x</a>
refused body <a href="data:text/html,<p>x</p>">x</a>
refused body <div title="javascript:alert(1)">x</div>
refused body <div data-x="vbscript:x">x</div>
refused body <img src="https://example.com/a.png" alt="x">
refused body <img src="a.png" alt="x">
refused body <img src="data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=" alt="x">
refused body <img src="data:image/png,raw" alt="x">
allowed body <img srcset="data:image/png;base64,iVBORw0KGgo= 1x, data:image/webp;base64,UklGRg== 2x" alt="x">
refused body <img srcset="data:image/png;base64,iVBORw0KGgo= 1x, https://example.com/b.png 2x" alt="x">
allowed body <picture><source srcset="data:image/webp;base64,UklGRg==" type="image/webp"><img src="data:image/png;base64,iVBORw0KGgo=" alt="x"></picture>
allowed body <svg><defs><path id="p" d="M0 0"/></defs><use href="#p"/></svg>
refused body <svg><use href="next.html#p"/></svg>
refused body <svg><defs><path id="p" d="M0 0"/><g id="g"><use href="#p"/></g></defs><use href="#g"/></svg>
refused body <svg><defs><path id="p" d="M0 0"/><use id="u" href="#p"/></defs><use href="#u"/></svg>
refused body <svg><use xlink:href="https://example.com/s.svg#p"/></svg>
allowed body <svg><image href="data:image/png;base64,iVBORw0KGgo=" width="1" height="1"/></svg>
refused body <svg><image href="https://example.com/a.png"/></svg>
allowed body <svg><defs><linearGradient id="g"><stop offset="0" stop-color="#fff"/></linearGradient></defs><rect fill="url(#g)" width="1" height="1"/></svg>
refused body <svg><defs><pattern id="p"/></defs></svg>
refused body <svg><defs><mask id="m"/></defs></svg>
refused body <svg><defs><path id="L%" d="M0 0"/></defs><use href="#L%"/></svg>
refused body <svg><defs><clipPath id="c"><use href="#p"/></clipPath><path id="p" d="M0 0"/></defs></svg>
refused body <svg><defs><clipPath id="a"><rect width="1" height="1"/></clipPath><clipPath id="b"><rect clip-path="url(#a)" width="1" height="1"/></clipPath></defs></svg>
allowed body <svg><defs><clipPath id="c"><rect width="1" height="1"/></clipPath></defs><rect clip-path="url(#c)" width="1" height="1"/></svg>
refused body <svg><defs><path id="p" d="M0 0"/></defs><rect fill="url(#p)" width="1" height="1"/></svg>
refused body <svg><defs><path id="p" d="M0 0"/><path id="p" d="M1 1"/></defs><use href="#p"/></svg>
refused body <svg><rect fill="url(https://example.com/a.svg#g)" width="1" height="1"/></svg>
```

## Inputs and buttons

```cases
allowed body <input type="checkbox" checked disabled>
allowed body <input type="email" value="a@example.com">
allowed body <button type="button">Save</button>
allowed body <button>Save</button>
refused body <input type="image" src="data:image/png;base64,iVBORw0KGgo=">
refused body <input type="file">
refused body <input type="submit">
refused body <button type="submit">Save</button>
refused body <button type=" button">Save</button>
refused body <input type="text" form="f">
```

## CSS

```cases
allowed head <style>body{font-family:system-ui;color:#222}</style>
allowed head <style>.logo{background:url(data:image/png;base64,iVBORw0KGgo=)}</style>
allowed head <style>.logo{background:url("data:image/png;base64,iVBORw0KGgo=")}</style>
allowed head <style>@font-face{font-family:F;src:url(data:font/woff2;base64,d09GMg==) format("woff2")}</style>
refused head <style>.c{clip-path:url(#clip)}</style>
refused head <style>@import "https://example.com/a.css";</style>
refused head <style>@IMPORT url(a.css);</style>
refused head <style>@namespace svg url(http://www.w3.org/2000/svg);</style>
refused head <style>.a{background:url(https://example.com/a.png)}</style>
refused head <style>.a{background:url(//example.com/a.png)}</style>
refused head <style>.a{background:url( https://example.com/a.png )}</style>
refused head <style>.a{background:url('a.png')}</style>
refused head <style>.a{background:u\72l(https://example.com/a.png)}</style>
refused head <style>.a{background:url(https\3a //example.com/a.png)}</style>
refused head <style>.a{background:ur/**/l(https://example.com/a.png)}</style>
refused head <style>.a{background:image-set("https://example.com/a.png" 1x)}</style>
refused head <style>.a{background:-webkit-image-set(url(https://example.com/a.png) 1x)}</style>
refused head <style>.a{background:cross-fade(url(a.png),url(b.png),50%)}</style>
refused head <style>.a{background:image("a.png")}</style>
refused head <style>.a{background:element(#x)}</style>
refused head <style>.a{background:paint(x)}</style>
refused head <style>.a{width:expression(alert(1))}</style>
refused head <style>.a{behavior:url(x.htc)}</style>
refused head <style>.a{-moz-binding:url(x.xml#b)}</style>
allowed head <style>html{scroll-behavior:smooth}</style>
allowed head <style>.behavior-x{color:red}</style>
refused head <style>.a{background:image-rect(url(data:image/png;base64,iVBORw0KGgo=),0,0,1,1)}</style>
refused head <style>.a{BEHAVIOR:url(x.htc)}</style>
refused head <style>.a::after{content:attr(data-x)}</style>
refused head <style>.a{background:url(data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=)}</style>
refused head <style>.a{background:url(data:font/woff2;base64,d09GMg==)}</style>
refused head <style>@font-face{font-family:F;src:url(https://example.com/f.woff2)}</style>
allowed body <div style="background:url(data:image/gif;base64,R0lGODlh)">x</div>
refused body <div style="background:url(https://example.com/a.png)">x</div>
refused body <div style="background:u&#114;l(https://example.com/a.png)">x</div>
```

## Encoding and size

- A page with a UTF-8 byte order mark is refused.
- A page that is not valid UTF-8 (the byte `0xFF`) is refused.
- A page of 1 MiB is allowed when every rule passes; one byte more is refused.
- A page with `<svg><defs><path id="p" d="M0 0"/></defs>` and then 1,000 `<use href="#p"/>`
  in the `<svg>` is allowed; with 1,001 it is refused.
