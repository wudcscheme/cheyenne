REBOL [
	Title: "HTTPd service"
	Author: "SOFTINNOV / Nenad Rakocevic"
	Version: 0.9.20
	Date: 01/03/2009
]

do-cache uniserve-path/libs/headers.r
do-cache uniserve-path/libs/url.r
do-cache uniserve-path/libs/html.r

install-service [
	name: 'HTTPd
	port-id: 80
	module: 'CGI
	auto-expire: 0:00:15
	started?: no
	verbose: 0
	
	dot: #"."
	lf: #"^/"
	nlnl: "^/^/"
	crlfcrlf: join crlf crlf
	not-nl: complement charset crlf
	dquote: #"^""
	log-e-16: log-e 16
	not-ws: complement charset " "

	conf: mod-list: mime-types: none
	handlers: make block! 10
	conf-parser: do-cache %misc/conf-parser.r
	mod-dir: %mods/
	incoming-dir: join cheyenne/data-dir %incoming/
	version: none
	
	keep-alive: "Keep-Alive"
	
	http-responses: [
		100 "Continue"
		101 "Switching Protocols"
		200 "OK"
		201 "Created"
		202 "Accepted"
		203 "Non-Authoritative Information"
		204 "No Content"
		205 "Reset Content"
		206 "Partial Content"
		300 "Multiple Choices"
		301 "Moved Permanently" 
		302 "Moved Temporarily" 
		303 "See Other"
		304 "Not Modified"
		305 "Use Proxy"
		307 "Temporary Redirect"
		400 "Bad Request"
		401 "Unauthorized"
		402 "Payment Required"
		403 "Forbidden"
		404 "Not Found"
		405 "Method Not Allowed"
		406 "Not Acceptable"
		407 "Proxy Authentication Required"
		408 "Request Time-Out"
		409 "Conflict"
		410 "Gone"
		411 "Length Required"
		412 "Precondition Failed"
		413 "Request Entity Too Large"
		414 "Request-URL Too Large"
		415 "Unsupported Media Type"
		416 "Requested Range Not Satisfiable"
		417 "Expectation Failed"
		500 "Server Error"
		501 "Not Implemented"
		502 "Bad Gateway"
		503 "Out of Resources"
		504 "Gateway Time-Out"
		505 "HTTP Version not supported"
	]
	
	http-error-pages: [
		400 "<html><body><h1>400 Bad request</h1></body></html>"
		404 "<html><body><h1>404 Page not found</h1></body></html>"
		501 "<html><body><h1>501 Request processing error</h1></body></html>"
	]
	
	foreach [code msg] http-responses [
		insert msg rejoin ["HTTP/1.1 " code #" "]
		append msg crlf
	]
	http-responses: make hash! http-responses

	phases: make hash! [
		method-support	[]
		url-translate 	[]
		url-to-filename []
		parsed-headers	[]
		filter-input	[]
		access-check	[]
		set-mime-type	[]
		make-response	[]
		filter-output	[]
		reform-headers	[]
		logging			[]
		clean-up		[]
		task-done 		[]
		task-failed		[]
		task-part		[]
	]
	
	do extension-class: has [list][
		list: extract phases 2
		forall list [change list to-set-word list/1]
		repend list [to-set-word 'service none]
		extension-class: context to-block list
	]

	proto-header: compose [
		Server			(append "Cheyenne/" version: system/script/header/version)
		Date			(none)
		Last-Modified	(none)
		Content-Length	(none)
		Content-Type 	(none)
		Connection		"close"
	]
	
	do-task: func [data req [object!]][
		shared/do-task/save data self req
	]
	
	reset-stop: does [stop-at: newline]
	
	make-tmp-fileinfo: does [
		make object! [
			bound: remains: buffer: port: none
			files: make block! 1
		]
	]
	
	make-tmp-filename: has [out][
		out: make file! 12
		until [
			clear out
			loop 8 [insert tail out #"`" + random 26]
			insert tail out ".tmp"
			not exists? incoming-dir/out
		]
		join incoming-dir out
	]
			
	make-http-session: does [
		make object! [
			in: make object! [
				headers: make block! 10
				status-line: method: url: content: path: target: 
				arg: ext: version: file: script-name: none
			]
			out: make object! [
				headers: copy proto-header
				content:
				status-line:
				forward:
				code: 
				mime: none
				length: 0
				header-sent?: no
				error: no
				log?: yes
			]
			auth: make object! [
				type: user: pass: state: port: header: save-events: none
			]
			state: 'request
			loops: 0
			handler: locals: cfg: file-info: vhost: app: tmp: none
		 ]
	]

	set 'install-HTTPd-extension func [body [block!] /local mod np][
		mod: make log-class []
		mod: make extension-class mod
		mod: make mod body
		bind second get in mod 'log in mod 'self
		mod/service: self

		if all [in mod 'order mod/order not empty? mod/order][
			foreach [phase blk] phases [
				np: reduce [mod/name get in mod :phase]
				switch select mod/order phase [
					first	[insert blk np]
					normal	[insert back back tail blk np]
					last	[insert tail blk np]
				]
			]
		]
		if in mod 'words [conf-parser/add-rules mod/words]			
		mod
	]
	
	select-vhost: func [req /local domain port?][	
		domain: select req/in/headers 'Host		
		unless req/cfg: any [
			all [
				domain
				lowercase domain		
				select conf req/vhost: any [
					all [
						port?: find domain #":"
						any [
							attempt [load domain]
							domain
						]
					]	
					attempt [to tuple! domain]
					to word! domain
				]
			]
			all [
				port? 
				select conf req/vhost: to word! domain: copy/part domain port?
			]
			select conf all [
				domain
				; --- extract the domain name (domain.suffix)
				domain: any [find/last domain dot domain]
				req/vhost: to word! any [find/reverse/tail domain dot domain]
			]
		][
			req/cfg: select conf req/vhost: 'default
		]			
	]
	
	fire-mod-event: func [event [word!] /local fun][
		foreach [name mod] mod-list [
			if fun: in mod event [
				do :fun self
				if verbose > 1 [
					log/info reform ["event" event "done (" name ")"]
				]
			]
		]
	]
	
	do-phase: func [req name /local state][
		foreach [mod do-handler] phases/:name [
			if verbose > 1 [
				log/info reform ["trying phase" name "(" mod ")"]
			]
			state: do-handler req
			if all [verbose > 1 logic? state][
				log/info "=> request processed"
			]
			if state [exit]
		]	
	]
	
; TBD: close connection on non-printable chars ?!
	parse-request-line: func [
		line ctx
		/short
		/local method url pos version lt path
	][
		either short [
			url: :line
		][ 
			parse/all ctx/status-line: copy line [
				copy method to #" " skip
				copy url [
					any [c: #"\" (change c slash) | not-ws] #" " 
					| [to lf lt: (if cr = lt/-1 [lt: 'cr])] | to end
				] skip [
					"HTTP/" copy version [to cr (lt: 'cr)| to lf]
					| [to cr (lt: 'cr)| to lf]
				]
			]
			unless url [url: ""]
			ctx/method: attempt [to word! method]
			ctx/version: attempt [trim version]
			stop-at: either lt = 'cr [crlfcrlf][nlnl]
			
			; --- Hack in the uniserve engine to move the read buffer back
			; --- (useful to handle the no-header case)
			insert/dup client/locals/in-buffer #" " 1 + to integer! lt = 'cr
		]	
		ctx/url: path: dehex trim url
		if all [url pos: any [find url #"?" find url #"#"]][
			ctx/arg: copy next pos
			ctx/target: path: trim copy/part url pos 
		]
		ctx/path: any [
			all [
				pos: find/last/tail path slash
				copy/part path ctx/target: trim pos
			]
			"/"
		]
		if all [
			ctx/target
			pos: find/last ctx/target #"."
			not empty? pos
		][
			ctx/ext: to word! pos
		]
		unless ctx/target [ctx/target: ""]		
		set in last client/user-data 'handler select handlers ctx/ext
	]
	
	name-chars: charset [#"a" - #"z" #"A" - #"Z" #"0" - #"9" "-_"]
	
	parse-headers: func [data ctx /local valid? name value EOH][
		valid?: parse/all data [
			any [cr | lf]
			any [
				copy name [some name-chars] #":" skip
				copy value to #"^/" skip (
					if attempt [name: to word! to string! name][					
						h-store ctx/headers name trim to string! value
					]
				)
			] EOH: to end
		]		
		reduce [valid? EOH]
	]
	
	decode-boundary: func [req /local h bound][
		all [
			h: select req/in/headers 'Content-type
			parse/all h [
				thru "multipart/form-data"
				thru "boundary=" opt dquote copy bound [to dquote | to end]
			]
			bound
			req/tmp/bound: head insert bound "--"
		]
	]
	
	open-tmp-file: func [tmp content /local name][
		append tmp/files name: make-tmp-filename
		repend content [mold name crlf]
		if tmp/port [close tmp/port]
		tmp/port: open/mode name [binary direct no-wait write new]
	]
	
	bufferize: func [tmp data /local pos][
		either 512 >= length? data [
			tmp/buffer: copy data
			pos: data
		][
			tmp/buffer: copy pos: skip tail data -512				
		]
		pos
	]
	
	stream-to-disk: func [req data /local tmp pos][
		tmp: req/tmp
		either pos: find data tmp/bound [			;-- search file end marker		
			insert/part tmp/port data skip pos -2 	;-- skip CRLF
			close tmp/port
			tmp/port: none		
			stream-to-memory req pos				;-- found, switch to memory
		][											
			insert/part tmp/port data bufferize tmp data
		]
	]
	
	stream-to-memory: func [req data /local tmp pos][
		tmp: req/tmp
		parse/all data [							;-- search file 
			any [
				thru tmp/bound 
				opt ["--" (append req/in/content data exit)]
				thru {name="} thru {"}
				opt [ {; filename="} thru crlfcrlf pos: break]
			]
		]
		either pos [								;-- found, switch to disk
			insert/part tail req/in/content data pos 
			open-tmp-file tmp req/in/content
			stream-to-disk req pos
		][
			insert/part tail req/in/content data bufferize tmp data
		]
	]
	
	process-content: func [req data /local tmp][
		tmp: req/tmp
		either tmp/bound [							;-- multipart/form-data
			if tmp/buffer [
				insert data tmp/buffer
				tmp/buffer: none
			]			
			either tmp/port [
				stream-to-disk req as-string data
			][
				stream-to-memory req as-string data
			]
		][
			unless tmp/port [						;-- raw mode
				append req/in/content "file="
				open-tmp-file tmp req/in/content
			]
			insert tmp/port data
		]
	]
	
	chunk-encode: func [data /local size len str][
		either empty? data [str: "0" len: 1][
			str: to string! to-hex len: length? data
			size: divide log-e len log-e-16
			if size > to integer! size [size: size - 1]
			len: subtract length? str size
		]
		insert data join copy at str len crlf	; TBD: use insert/part
		head insert tail data crlf
	]
	
	send-chunk: func [cu /local ctx out][
		ctx: cu/out
		ctx/length: ctx/length + length? ctx/content
		either ctx/header-sent? [
			write-client chunk-encode ctx/content
		][
			do-phase cu 'reform-headers
			unless ctx/status-line [
				ctx/status-line: select http-responses ctx/code
			]
			unless ctx/headers/Content-Type [
				h-store ctx/headers 'Content-Type form ctx/mime
			]
			h-store ctx/headers 'Transfer-Encoding "chunked"
			write-client out: join ctx/status-line form-header ctx/headers
			write-client chunk-encode ctx/content
			if all [verbose > 1 out][log/info ["Response=>^/" out]]
			ctx/header-sent?: yes
		]
	]
	
	process-queue: has [q req][
		q: client/user-data
		if empty? q [log/warn "empty queue"]	;-- should never happen!		
		while [
			all [
				not empty? q
				q/1/out/code
			]
		][		
			if finish-response first q [remove q]
		]
	]
	
	respond: func [req /local q][
		unless req/out/code [do-phase req 'access-check]
		unless req/out/code [do-phase req 'set-mime-type]
		unless req/out/code [do-phase req 'make-response]	
		either req/out/forward [				;-- early check for earlier forward
			do-request req	
		][
			process-queue
		]
	]

	do-request: func [req /local new line url ni][
		if verbose > 1 [log/info ["internal request: " req/out/forward]]	
		if req/loops > 3 [
			req/out/forward: none
			process-queue
			exit
		]
		change find client/user-data req new: make-http-session
		new/in: ni: req/in
		new/loops: req/loops + 1
		h-store new/in/headers 'Internal-Referer url-encode req/in/url
		ni/file: none							; fix 30/11/2008 (Will)
		if url? line: req/out/forward [
			url: parse-url line
			if url/port-id [repend url/host [":" url/port-id]]
			h-store ni/headers 'Host url/host
			ni/status-line: line: join url/path url/target
		]		
		parse-request-line/short line ni	
		do-phase new 'url-translate
		do-phase new 'parsed-headers
		select-vhost new		
		do-phase new 'url-to-filename
		respond new
	]	
	
	finish-response: func [req /local q out data value keep?][
		q: client/user-data
		out: req/out
		
		unless out/header-sent? [
			do-phase req 'filter-output
			if req/out/forward [
				do-request req
				return false ;-- keep request in queue
			]
			do-phase req 'reform-headers

			if all [out/content empty? out/content][out/content: none]
			if all [not out/content out/code >= 400][
				out/content: select http-error-pages out/code
				out/mime: pick [text/html application/octet-stream] out/code >= 400 
			]		
			either out/content [
				unless out/headers/Content-Type [
					h-store out/headers 'Content-Type form out/mime
				]			
				h-store out/headers 'Content-Length form any [
					all [file? out/content req/file-info/size]
					length? out/content
				]
			][
				if out/code = 200 [out/code: 204]
			]
			unless out/status-line [
				out/status-line: select http-responses out/code
			]
			if any [
				1 < length? q
				all [
					any [
						out/code < 300		;FF reacts badly on 301/302 with keepalive
						all [400 <= out/code out/code < 500]
						out/code = 304
					]
					value: select req/in/headers 'Connection
					find value keep-alive
				]
			][		
				h-store out/headers 'Connection keep-alive
				keep?: yes
			]
			write-client data: join out/status-line form-header out/headers
		]

		if all [out/content req/in/method <> 'HEAD][write-client out/content]
		if all [verbose > 0 data][log/info ["Response=>^/" data]]
		
		if any [
			all [not keep? 1 = length? q]
			out/code = 405
		][close-client]
		
		do-phase req 'logging
		do-phase req 'clean-up
		if req/tmp [
			foreach file req/tmp/files [attempt [delete file]]
		]
		
		true	;-- remove request from queue
	]
	
	on-quit: does [
		;---TBD: add a deferred restart mode
		fire-mod-event 'on-quit
	]
	
	on-reload: does [
		started?: no
		fire-mod-event 'on-reload
		foreach [name list] phases [clear list]
		on-load
		on-started
		fire-mod-event 'on-reloaded
	]

	on-load: has [out cnt][
		mime-types: load-cache %misc/mime.types
		clear handlers
		conf: conf-parser/read self
		if verbose > 3 [
			out: copy ""
			foreach [name phase] phases [
				append out reform ["phase:" name #"^/"]
				cnt: 0
				foreach [mod fun] phase [append out rejoin [tab cnt: cnt + 1 #"." mod newline]]
			]		
			log/info ["Phases list:^/" out]
			out: none
		]
	]
	
	on-started: has [name mod fun][
		unless started? [
			fire-mod-event 'on-started
			started?: yes
		]
	]
	
	on-new-client: does [
		set-modes client [
			receive-buffer-size: 16384
			send-buffer-size: 65536
		]
		reset-stop		
		client/user-data: make block! 1
	]
	
	
	on-received: func [data /local req len limit q][
		q: client/user-data
		if empty? q [insert q copy [[state request]]] ; avoid wasting a call to make-http-session
		req: last q
		switch req/state [
			request [			
				len: length? data
				if any [
					len < 6
					len > 2048
				][
					if verbose > 1 [log/info ["Dropping invalid request=>" data]]
					close-client
					reset-stop
					exit
				]
				either block? req [
					change back tail q req: make-http-session
				][
					append q req: make-http-session
				]				
				if verbose > 0 [
					log/info ["================== NEW REQUEST =================="]
					log/info ["Request Line=>" trim/tail to-string data]
				]
				parse-request-line data req/in
				do-phase req 'method-support
				do-phase req 'url-translate
				req/state: 'headers
				exit
			]
			headers [
				if verbose > 0 [log/info ["Request Headers=>" to-string data]]
				parse-headers data req/in
; filter HOST: xxx.xxx.xxx.xxx (scanners) ?				
				do-phase req 'parsed-headers
				select-vhost req				
				do-phase req 'url-to-filename
				reset-stop
				if find [POST PUT] req/in/method [
					req/state: 'data
					either len: select req/in/headers 'Content-Length [
						limit: select req/cfg 'post-max
						len: any [attempt [to integer! len] 0]
						stop-at: either all [limit len > limit][req/out/code: 406 limit][len]
						limit: any [
							select conf/globals 'post-mem-limit
							select req/cfg 'post-mem-limit
							100'000
						]
						if stop-at > limit [
							unless exists? incoming-dir [make-dir incoming-dir]
							req/tmp: make-tmp-fileinfo
							decode-boundary req							
							req/in/content: make string! 1024
							req/tmp/remains: stop-at						
							req/state: 'stream-in
							stop-at: limit
						]
						exit
					][
						req/out/code: 400
					]
				]
			]
			data [
				if verbose > 0 [
					either verbose > 1 [
						log/info ["Posted data=>" copy/part to-string data 80]
					][
						log/info ["Posted data=>" length? to-string data]
					]
				]
				if limit: find/part skip client/locals/in-buffer stop-at #{0D0A} 2 [
					remove/part limit 2			 ; avoid IE extra CRLF issues
				]
				req/in/content: data
				do-phase req 'filter-input
			]
			stream-in [
				process-content req data				
				len: req/tmp/remains: req/tmp/remains - stop-at
				if stop-at > len [stop-at: len]				
				either zero? stop-at [				
					if req/tmp/port [attempt [close req/tmp/port]]
					req/tmp/port: none
					do-phase req 'filter-input
				][exit]
			]
		]
		respond req				
		req/state: 'request
		reset-stop
	]
	
	on-task-part: func [data req][
		req/out/content: data
		do-phase req 'task-part
	]
	
	on-task-done: func [data req][
		req/out/content: data
		do-phase req 'task-done
	]
	
	on-task-failed: func [reason req][	
		req/out/content: reason	
		do-phase req 'task-failed
	]
	
	on-close-client: does [
		if verbose > 1 [log/info ["Connection closed"]]
		;--- TBD: close properly tmp disk files (when upload has been interrupted)
	]
]