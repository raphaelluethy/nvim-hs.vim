" This script is used to manage compiling and starting nvim-hs based plugin hosts.
"
" Since commands a la 'stack exec' can delay the startup time of a plugin
" significantly (a few secondes) and executing the appropriately built
" binary is almost instant, this script uses a simple caching mechanism to
" optimistically start existing binaries whose location is read from a
" cache file.
"
" Only if there is no cached entry or the binary inside that entry doesn't
" exist, the compilation is done before starting the binary/plugin host.
"
" If the started binary is old, the user is notified of this and can restart
" neovim to have it start with the current version of the plugins.

" Exposed API {{{1

function! nvimhs#start(workingDirectory, name, args)
	try
		let l:chan = remote#host#Require(a:name)
		if l:chan
			try
				" Hack to test if the channel is still working
				call rpcrequest(l:chan, 'Ping', [])
				return l:chan
			catch '.*No provider for:.*'
				" Message returned by nvim-hs if the function does not exist
				return l:chan
			catch
				" Channel is not working, call the usual starting mechanism
			endtry
		endif
	catch
		" continue
	endtry
	let l:starter = get(g:, 'nvimhsPluginStarter', {})
	if len(l:starter) == 0
		let l:starter = nvimhs#stack#pluginstarter()
	endif

	let l:Factory = function('s:buildStartAndRegister'
				\ , [ { 'pluginStarter': l:starter
				\     , 'cwd': a:workingDirectory
				\     , 'name': a:name
				\     , 'args': a:args
				\     }
				\   ])
	call remote#host#Register(a:name, '*', l:Factory)
	return remote#host#Require(a:name)
endfunction

" This will forcibly close the RPC channel and call nvimhs#start. This will
" cause the state of the plugin to be lost. There is no standard way to keep
" state across restarts yet, so use with care.
function! nvimhs#restart(name)
	try
		if remote#host#IsRunning(a:name)
			call chanclose(remote#host#Require(a:name))
		endif
	finally
		call nvimhs#start('', a:name, [])
	endtry
endfunction

" This function basically calls nvimhs#restart, except that the
" recompilation of the plugin is guaranteed. For implementation reasons,
" this variant can be useful if you did not commit your changes in the
" repository that the plugin resides in.
function! nvimhs#compileAndRestart(name)
	call nvimhs#restart(a:name)
endfunction

" Utility functions {{{2

" Synchronously determine the git commit hash of a directory.
function! nvimhs#gitCommitHash(directory)
	return join(
				\ nvimhs#execute(a:directory,
				\   { 'cmd': '[ -z "$(git status --porcelain=v1 2>/dev/null)" ] && git rev-parse HEAD 2>/dev/null || echo no-repository-or-dirty-repository-state'})
				\ , '')
endfunction

" Internal functions {{{1
" The output of started processes via jobstart seems to always leave a
" trailing empty line. This function removes it.
function! s:removeTrailingEmptyLine(lines)
	if len(a:lines) && ! len(a:lines[-1])
		return a:lines[0:-2]
	else
		return a:lines
	endif
endfunction

" Jobs are started with buffered output for stdout and stderr, this function
" is used as the callback to store that output without creating temporary
" files or buffers.
function! s:appendToList(list, jobId, data, event)
	for l:e in s:removeTrailingEmptyLine(a:data)
		call add(a:list, l:e)
	endfor
endfunction

" General template for a callback function that also allows chaining
" commands. The approach is continuation based and works as follows.
function! s:onExit(directory, cmd, out, err, jobId, code, event)
	if a:code != 0
		if type(a:cmd) == type([])
			let l:cmd = join(a:cmd)
		else
			let l:cmd = join(a:cmd.cmd)
		endif
		echohl Error
		echom 'Failed to execute (cwd: ' . a:directory . '):