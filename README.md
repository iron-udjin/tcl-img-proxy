# TCL Image Proxy
The TCL Image Proxy is an application written in TCL that utilizes the `magick` console command from [ImageMgick](https://imagemagick.org) as its conversion backend.

### Description
The "TCL Image Proxy" allows you to retain only the original image on the website. All other versions of the image will be generated on-demand and cached by [Nginx](https://nginx.org/) or any other application with proxy/cache functionality.

Let's say you have a website where you share images. For different pages, you require images with varying dimensions. For example, the original image has a resolution of `1920x1080`. On the category page, you need images with a width of `320` and a proportional height. On the page with a brief image description, you need an image with a width of 640. For visitors using mobile phones, you need images with a width of `150` in the webp format. In this case, you need to store the original full-sized image as well as several other versions of the same image but with different dimensions.

### How does it work?

The "TCL Image Converter Proxy" is an application that listens on the HTTP port (by default, on localhost and port 8080), receives HTTP GET requests, and converts image files based on the request parameters.

Available parameters are:

- `w` - image width. Default: `150 320 420 630 640 900 1200 1280 1600 1920`
- `q` - quality. Default: `75 85 90`
- `f` - output format: `png webp jpg jpeg`
- `hash` - see `Encryption` section below.

Example: http://localhost:8080/test.jpg?w=640&q=85&f=webp - This URL will convert the image "test.jpg" to the webp format with a width of 640 pixels and proportional height. The image will have a quality of 85 and will be output directly in the browser.

### Support OS

- FreeBSD (should also work on any other *BSD which has required dependencies)
- Linux
- Windows
- MacOS

### Dependencies

- TCL 8.6 or newer (should work with older versions but untested)
- tcllib 1.21 or newer
- ImageMagick 7 (should work with ver 6 but you need to set `converter_bin` cmd line option to `convert`)

### Features

- lightweight
- without extra dependencies (only tcl and ImageMagick)
- async socket request processing based on [chan event](https://www.tcl.tk/man/tcl/TclCmd/chan.html#M24) in non-blocking mode
- async read `magick` command output and hadnle `stdout` and `stderr` separately in non-blocking mode
- fully async and non-blocking logger with separate message queue which runs only when `event loop` is idle (see: [after idle](https://www.tcl.tk/man/tcl/TclCmd/after.html#M9))
- generates [`Etag`](https://en.wikipedia.org/wiki/HTTP_ETag) header (based on `md5` from predefined entropy sources)
- sets correct [`Content-type`](https://en.wikipedia.org/wiki/Media_type) and `Last-Modified` headers
- it utilizes the `Transfer-Encoding: chunked` header, enabling the immediate transmission of data as soon as the first chunk of the converted image is received from the `magick` command's output pipe
- the image location can be on the local filesystem or stored in external storage systems such as Amazon S3 or any other storage accessible via HTTP(s). See: `External image storage` section below.

### Command line options
```
Usage: ./tcl-img-proxy.tcl <params> or tclsh ./tcl-img-proxy.tcl <params>
Example: tclsh ./tcl-img-proxy.tcl -addr 127.0.0.1 -port 8080 -img_root_prefix /tmp/images

-addr: Listen address (IP or hostname). Default: localhost.
-port: Listen port. Default: 8080.
-log_level: Log levels:
    0 - disable (default)
    1 - log to file
    2 - log to stdout only (useful for debugging).
-log_file: File to store logs. Default: /tmp/tcl-img-proxy.log.
-img_root_prefix: Image root directory or URL prefix. Default: current directory (In Windows can be differ)
-converter_bin: Path to the `converter` program. Default: magick (without absolute path).
-aes_enc_key: Key for AES hash decryption.
-aes_enc_iv: Initialization vector for AES hash decryption.
-converter_timeout: The timeout duration for the converter program, after which it will be terminated. Default: 10 seconds (applies to all platforms except Windows).
```

### Encryption

In some cases there is no need to give visitors possibility to play with some conversion parameters. Currently, it is exclusively utilized for transferring the `-crop` parameter through an encrypted hash in `AES-128-CBC`.
Excample code in php for generatiing hash parameter:
```php
<?php
$cipher = "aes-128-cbc";
$key = "VYtvNgVc7KWYoqpi"; // Encryption Key (example, change it!)
$iv = "97Wm7KsbXneAgRts"; // Initialization Vector (example, change it!)
$data = "174x174+222+54"; // crop parameters
$encrypted_data = trim(openssl_encrypt($data, $cipher, $key, 0, $iv), "="); // encrypt data and trim trailing `=`
echo "Encrypted Text: " . $encrypted_data . "\n";
```
This script will produce:
`Encrypted Text: ltO4kvrgYFys966ICxPFXw`
You can use the code above in your web-engine to generate URLs with 'hidden' crop parameters. Example: http://localhost:8080/test.jpg?w=640&q=85&f=webp&hash=ltO4kvrgYFys966ICxPFXw
On the application side you need to set `-aes_enc_key` and `-aes_enc_iv` command line options respectively.
You can generate `key` and `iv` from the command line: `openssl rand -hex 8`

### Extending
In the source code you can find block:
```tcl
set params {
    w { 
        allow {150 320 420 630 640 900 1200 1280 1600 1920}
        cmd_param { -resize ${in_param_value}x}
    }   
    q { 
        allow {75 80 85 90} 
        cmd_param { -quality ${in_param_value}}
    }   
    f { 
        allow {png webp jpg jpeg}
        cmd_param { ${in_param_value}:-}
    }   
}
```
`params` is a TCL [dictionary](https://www.tcl.tk/man/tcl/TclCmd/dict.html). You can add/edit/remove formats (`f` block), width (`w` block) and quality (`q` block). `cmd_param` - what will be added as command line option to `magick` command. Note: the formats has to be supported by ImageMagick. Check: `magick identify -list format`.

### External image storage
To use any storage accessible by HTTP(s) simple add URL prefix to `-img_root_prefix` command line parameter.

Example:
https://example.com/storage/2023/05/12/test.jpg
Add: `-img_root_prefix https://example.com`
It will be available: http://localhost:8080/storage/2023/05/12/test.jpg?w=640&q=85&f=webp

**Note**: HTTP(s) support is disabled by default in`ImageMagick` in mose cases. To enable it add or edit `policy.xml`:
```xml
<policy domain="coder" rights="read" pattern="HTTPS" />
<policy domain="coder" rights="read" pattern="HTTP" />
```
The file is usually located: `/etc/ImageMagick-7/policy.xml` in Linux and `/usr/local/etc/ImageMagick-7/policy.xml` in FreeBSD.
To make sure that everything is fine, run in the console: `magick identify -list policy`
```
Path: /usr/local/etc/ImageMagick-7/policy.xml
...
  Policy: Coder
    rights: Read 
    pattern: HTTPS
  Policy: Coder
    rights: Read 
    pattern: HTTP
...
```

### Security
- the application uses only URL parameters and their values from the predefined list.
- the application on any error sends `404 Not Found` to the visitor for two reasons:
1. attacker shouldn't know that converter has returned an error because it can be used at least for other attack vectors
2. to prevent or at least reduce the consequences of [DoS attacks](https://en.wikipedia.org/wiki/Denial-of-service_attack) you can set Nginx (or any other proxy) to cache 404 erros and filter parameters on Nginx proxy side.
- sometimes, security vulnerabilities are discovered in ImageMagick. Therefore, it is important to always use the latest stable version
- it is a good practice (if feasible) to place ImageMagick within an isolated environment and utilize it from there.

### Proxy settings and optimization for high load
In the `nginx_proxy.conf` you can find sample `nginx` configuration. All that you need is to change `server_name` and `root` parameters and possibly change `proxy_cache_path` locatio (`/tmpfs` by default). Nginx Proxy caches images for 1 day by default (`inactive=24h` config option). If an image wasn't requested within a day - it will be removed from cache.

To create proxy cache storage in [tmpfs](https://en.wikipedia.org/wiki/Tmpfs), run as root: `mkdir /tmpfs` and add following line in `/etc/fstab`:
```
tmpfs   /tmpfs tmpfs defaults 0 0
```
It's **highly** recommend to use TCL Image Proxy only with proxy/cache on the front of it in production. Without cache it can utilize all server's resources (especially CPU).

### Proxy Cache bypass
If you have replaced the original image and need to refresh the cache, you can add a timestamp to the URL parameters list. This will create a unique URL for the updated image, bypassing any cached versions and ensuring that the latest version is fetched. Example: https://example.com/test.jpg?w=640&q=85&f=webp&timestamp=20230515173755 The old version of the converted image will automatically disappear after a day of inactivity.
