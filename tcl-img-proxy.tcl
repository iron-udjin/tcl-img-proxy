#!/usr/bin/env tclsh

package require md5
package require aes

# define default paramenets
set addr "localhost"
set port 8080
# default images root prefix is home directory
set img_root_prefix {./}
if {[lindex $tcl_platform(os) 0] eq "Windows"} {
    set converter_bin "magick.exe"
} else {
    set converter_bin "magick"
}
set converter_timeout 10
set log_file "/tmp/image_converter.log"
set log_level 0

# Encryption
set aes_enc_key ""
set aes_enc_iv ""
set is_img_prefix_url 0

if {$argc == 1} {
    puts "Usage: $argv0 <params> or tclsh $argv0 <param>
Example: tclsh $argv0 -addr 127.0.0.1 -port 8080 -img_root_prefix /tmp/images

-addr: Listen address (IP or hostname). Default: localhost.
-port: Listen port. Default: 8080.
-log_level: Log levels:
    0 - disable (default)
    1 - log to file
    2 - log to stdout only (useful for debugging).
-log_file: File to store logs. Default: /tmp/image_converter.log.
-img_root_prefix: Image root directory or URL prefix.
-converter_bin: Path to the `converter` program. Default: magick (without absolute path).
-aes_enc_key: Key for AES hash decryption.
-aes_enc_iv: Initialization vector for AES hash decryption.
-converter_timeout: The timeout duration for the converter program, after which it will be terminated. Default: 10 seconds (applies to all platforms except Windows)."
    exit 1
}

proc wrong_start_params {param val} {
    puts stderr "Wrong start parameter: $param $val\nPlease check: --help"
    exit 1
}

# check params
if {[expr $argc % 2]} {
    puts stderr "Wrong param list. Please check: --help"
        exit 1
}
for {set i 0} {$i<$argc} {incr i} {
    set param [string trim [lindex $argv $i] -]
    set val [lindex $argv [expr $i + 1]]
    # puts "param: $param val: $val"
    switch -glob -- $param {
        addr {
            set addr $val
        }
        port {
            if {![regexp {^\d+$} $val]} {wrong_start_params -$param $val}
            set $param $val
        }
        log_level {
            if {![regexp {^[0-2]$} $val]} {wrong_start_params -$param $val}
            set $param $val
        }
        log_file {
            set $param $val
        }
        img_root_prefix {
            set is_img_prefix_url [regexp {^https?} $val]
            if {!$is_img_prefix_url} {
                if {![file exists $val]} {
                    puts stderr "Image directory $val does not exists"
                        exit 1
                } elseif {![file isdirectory $val]} {
                    puts stderr "Image directory $val is not directory"
                        exit 1
                } elseif {![file readable $val]} {
                    puts stderr "Image directory $val is not readable"
                        exit 1
                }
            }
            set $param $val
        }
        converter_bin {
            if {[file isfile $val] && [file exists $val] && [file executable $val]} {
                set $param $val
            } else { 
                puts stderr "converter_bin file `$val` is a directory or does not exisis or not executable "
                exit 1
            }
        }
        aes_enc_key {
            set $param $val
        }
        aes_enc_iv {
            set $param $val
        }
        converter_timeout {
            if {![regexp {^\d+$} $val]} {wrong_start_params -$param $val}
            set $param $val
        }
    }
    incr i
}

# defune allowed values of image conversion
set params {
    w {
        allow {150 320 420 630 640 900 1200 1280 1600 1920}
        cmd_param { -resize ${in_param_value}x}
    }
    q {
        allow {75 85 90}
        cmd_param { -quality ${in_param_value}}
    }
    f {
        allow {png webp jpg jpeg}
        cmd_param { ${in_param_value}:-}
    }
}

# validate mandatory variables before start
if {$img_root_prefix eq {./}} {
    puts "Worning: you didn't set -img_root_prefix <PATH> paramener. img_root_prefix will be used as current dirrectory: [file normalize $img_root_prefix]"
}

# if log to file is enabled - check if we can write to file
if {$log_level} {
    if [catch {set log_chan [open $log_file a] } error] {
        puts stderr "Could not open $log_file for writing: $error"
        exit 1
    } else {
        chan configure $log_chan -blocking 0 -buffering line
    }
}


# prepare global stderr pipe for running `converter` subprocesses
lassign [chan pipe] ro_error_pipe wo_error_pipe
chan event $ro_error_pipe readable "read_stderr_pipe $ro_error_pipe"
chan configure $ro_error_pipe -blocking 0 -translation cr

proc read_stderr_pipe {ro_error_pipe} {
    logger [string trimright [chan read $ro_error_pipe] "\n"]
}

set log_queue_switch 0
set log_queue_lock {}
coroutine async_log_flush_callback apply {{} {
    global log_queue log_queue_switch log_queue_lock log_chan
    while {1} {
        yield
        set cur_log_queue_switch $log_queue_switch
        set log_queue_switch [expr {!$log_queue_switch}]
        puts $log_chan [join $log_queue($cur_log_queue_switch) "\n"]
        flush $log_chan
        set log_queue($cur_log_queue_switch) {}
        set log_queue_lock {}
    }
}}

proc logger {log} {
    global log_level log_chan log_queue log_queue_switch log_queue_lock
    if {$log_level == 1} {
        lappend log_queue($log_queue_switch) "[time_now]: $log"
        if {$log_queue_lock eq ""} {
            set log_queue_lock [after idle async_log_flush_callback]
        }
    } elseif {$log_level == 2} {
        puts "[time_now]: $log"
    }
}

proc time_now {{tz ""}} {
    global timezone
    set systime [clock seconds]
    if {$tz ne ""} {
        return [clock format $systime -format {%a, %d %b %Y %H:%M:%S} -timezone GMT]
    }
    return [clock format $systime -format {%a, %d %b %Y %H:%M:%S}]
}

proc return_404 {chan log} {
    global log_level
    try {
        puts $chan "HTTP/1.1 404\nContent-type: text/html; charset=UTF-8\nConnection: close\n"
    } on error {resunt options} {}
    close_socket_handler $chan
    if {$log_level} {
        logger "404 $log"
    }
}

proc handle_client {chan clientaddr port} {
    chan configure $chan -translation binary -blocking 0
    chan event $chan readable [list handle_input $chan]
}

proc handle_input {chan} {
    global params img_root_prefix converter_bin aes_enc_key aes_enc_iv log_level timezone log_file converter_timeout wo_error_pipe is_img_prefix_url tcl_platform
    set request [read $chan]
    if {[string length $request]>4096} {
        logger "HTTP request header too large - possible DOS attack"
        close_socket_handler $chan
        return
    } elseif {$request eq ""} {
        close_socket_handler $chan
        return
    }
    # puts "request: $request"
    set method [lindex [split $request] 0]
    set url [lindex [split $request] 1]
    if {$method != "GET"} {
        return_404 $chan "Error: empty or bad request method received: $method"
        return
    } else {
        if {[regexp {\?(.*)} $url -> match] && $match != ""} {
            #set vars_raw [split [string trimleft $match "?"] "&"]
            set vars [split [string trimleft $match "?"] "&"]
        } else {
            return_404 $chan "$url Error: no valid query string provided"
            return
        }
    }

    # make sure the hash variable has base64() endoded data without trailing =
    if {[regexp {(?:^|\s)hash=([A-Za-z0-9+/]+)(?:\s|$)} $vars -> hash]} {
        # perform base64 decode and decrypt data
        set data_raw [::aes::aes -dir decrypt -mode cbc -iv $aes_enc_iv -key $aes_enc_key [binary decode base64 $hash]]
        # make sure we receive correct crop parameters. [\x01-\x1b]* means trailing data according to aes RFC
        if {[regexp {^(\d+x\d+\+\d+\+\d+)[\x01-\x1b]*$} $data_raw -> data]} {
            set convert_cmd_params " -crop $data"
        } else {
            # return 404 if wrong decrypted data
            return_404 $chan "$url Rrror: wrong decoded crop parameters: $data_raw"
            return
        }
    }

    # processing params: w q f
    dict for {in_param val} $params {
        if {[regexp "(?:^|\\s)$in_param=(\[a-z0-9\]{1,4})(?:\\s|$)" $vars -> in_param_value]} {
            # make sure we receive correct value of parameter which exists in our allowed list
            if {[expr [lsearch [dict get $val allow] $in_param_value] >= 0]} {
                # substitute defined parameters by received values
                append convert_cmd_params [subst [dict get $val cmd_param]]
            } else {
                # return 404 if some of input values don't fit our allow list
                return_404 $chan "$url wrong parameter $in_param, value: $in_param_value"
                return
            }
        }
    }
    if {$is_img_prefix_url} {
        set file_absolute_path "$img_root_prefix[lindex [split $url {?}] 0]"
    } else {
        # local file absolute path
        set file_absolute_path "[file normalize $img_root_prefix][lindex [split $url {?}] 0]"
    }
    # make sure that the file exists and we didn't hit an error before
    if {![file exists $file_absolute_path] && $is_img_prefix_url == 0} {
        return_404 $chan "$url Error: file $file_absolute_path does not exist"
        return
    } elseif {![info exists convert_cmd_params]} {
        return_404 $chan "$url Error: empty convert cmd line params"
        return
    }
    # if output format isn't defined (which has to be last word in convert_cmd_params list and end with `:-`) - use file extension as an output format
    if {[regexp {\s(\w+):-$} $convert_cmd_params -> ext] == 0} {
        # getting extension without dot
        set ext [string trim [file extension $file_absolute_path] "."]
        # set ext to lower case if case file extension is in upper case
        set ext [string tolower $ext]
        append convert_cmd_params " $ext:-"
    }

    # fix for jpeg and set mime type
    if {$ext eq "jpg"} {
        set mimetype image/jpeg
    } else {
        set mimetype image/$ext
    }
    # generate Etag
    set etag [string tolower [::md5::md5 -hex "$file_absolute_path [time_now GMT] $convert_cmd_params"]]
    # make Last-Modified header
    set lm "[time_now GMT] GMT"

    set time_start [clock milliseconds]
    set cmdline "$converter_bin $file_absolute_path$convert_cmd_params"
    if {[lindex $tcl_platform(os) 0] eq "Windows"} {
        set fd [open "|$cmdline 2>@$wo_error_pipe" r]
    } else {
        set fd [open "|timeout $converter_timeout $cmdline 2>@$wo_error_pipe" r]
    }
    # prepare headers
    append headers "HTTP/1.1 200 OK\n"
    append headers "Content-type: $mimetype\n"
    append headers "Last-Modified: $lm\n"
    append headers "Etag: $etag\n"
    append headers "Connection: close\n"
    append headers "Transfer-Encoding: chunked\n"

    # tell file descriptor to process file in binary format
    chan configure $fd -translation binary -encoding binary -blocking 0 -buffering none
    set co_name "pipe_process_co_$chan"
    coroutine $co_name process_pipe_output $fd $chan $cmdline $url $headers $time_start
    chan event $fd readable [list $co_name]
}

proc close_socket_handler {chan} {
    try {
        close $chan
    } on error {result options} {
        # logger "Socket error: $result"
        # puts $result
        # puts $options
    }
}

proc data_eof_handler {fd chan url cmdline headers time_start} {
    global converter_timeout log_level
        set tcl_precision 4
        set time_end [clock milliseconds]
        set time_diff [expr [clock milliseconds] - $time_start]
        if {$time_diff>1000} {
            set time_diff "[expr $time_diff.000 / 1000]s"
        } else {
            set time_diff "${time_diff}ms"
        }
    if {[catch {chan event $fd readable {}} err]} {
        logger "404 $url Pipe descriptor inaccessible"
        close_socket_handler $chan
    } else {
        chan configure $fd -blocking 1
        try {
            close $fd
        } trap CHILDSTATUS {result options} {
            if {[lindex [dict get $options -errorcode] 2] == 124} {
                return_404 $chan "$url $time_diff Error: timeout from `converter` (${converter_timeout} sec). Process killed.\nCommand: $cmdline"
            } else {
                return_404 $chan "$url $time_diff `converter` returned error (see above)\nCommand: $cmdline"
            }
        } on ok {} {
            logger "200 $url $time_diff" 
                close_socket_handler $chan
        }
    }
    if {[info coroutine] ne ""} {
        rename [info coroutine] {}
    }
}

proc data_send_handler {chan data fd} {
    try {
        puts $chan $data
    } on error {result options} {
        logger "Client closed connection: $result"
        chan event $fd readable {}
        close $fd
        if {[info coroutine] ne ""} {
            rename [info coroutine] {}
        }
    }
}

proc process_pipe_output {fd chan cmdline url headers time_start} {
    yield
    set first_chunk [chan read $fd]
    if {$first_chunk ne ""} {
        set chunk_size [string length $first_chunk]
        data_send_handler $chan "$headers\n[format "%x\n%s" $chunk_size $first_chunk]" $fd
    } elseif {[eof $fd]} {
        data_eof_handler $fd $chan $url $cmdline $headers $time_start
    }
    yield
    while {1} {
        set chunk [chan read $fd]
        if {$chunk ne ""} {
            set chunk_size [string length $chunk]
            data_send_handler $chan [format "%x\n%s" $chunk_size $chunk] $fd
        } elseif {[eof $fd]} {
            data_send_handler $chan "0\n" $fd
            data_eof_handler $fd $chan $url $cmdline $headers $time_start
        }
        yield
    }
}

if {[catch {socket -server handle_client -myaddr $addr $port} error]} {
    puts stderr "$error: $addr:$port"
    puts -nonewline stderr "Trying 10 more seconds: "
    set i 10
    while {1} {
        after 1000
        if {[catch {socket -server handle_client -myaddr $addr $port}]} {
            puts -nonewline stderr "$i "
            set i [expr $i - 1]
        } else {
            puts ""
            break
        }
        if {!$i} {
            puts stderr "\nSocket still busy. Quitting..."
            exit 1
        }
    }
}
puts "Ready for processing requests on $addr:$port"

vwait forever
