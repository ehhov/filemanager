" filemanager - file explorer and manager plugin for Vim and Neovim intended 
" to be as straightforward as possible and never do anything unexpected.
"
" Author: Kerim Guseynov
" URL: https://github.com/ehhov/filemanager
"

if exists('g:loaded_filemanager')
	finish
endif
let g:loaded_filemanager = 1


command! -bang -nargs=? -complete=dir  L  call s:spawn(<q-args>, expand('<bang>'), 1)
command! -bang -nargs=? -complete=dir  V  call s:spawn(<q-args>, expand('<bang>'), 1)
command! -bang -nargs=? -complete=dir  H  call s:spawn(<q-args>, expand('<bang>'), 0)


" Internal magic {{{
let s:opencmd              = get(g:, 'filemanager_opencmd',     'xdg-open')
let s:winsize              = get(g:, 'filemanager_winsize',             20)
let s:preferleft           = get(g:, 'filemanager_preferleft',           1)
let s:preferbelow          = get(g:, 'filemanager_preferbelow',          1)
let s:orientation          = get(g:, 'filemanager_orientation',          1)
let s:alwaysfixwinsize     = get(g:, 'filemanager_alwaysfixwinsize',     1)
let s:bookmarkonbufexit    = get(g:, 'filemanager_bookmarkonbufexit',    1)
let s:usebookmarkfile      = get(g:, 'filemanager_usebookmarkfile',      1)
let s:writebackupbookmarks = get(g:, 'filemanager_writebackupbookmarks', 0)
let s:notifyoffilters      = get(g:, 'filemanager_notifyoffilters',      1)
let s:showhidden           = get(g:, 'filemanager_showhidden',           1)
let s:respectgitignore     = get(g:, 'filemanager_respectgitignore',     1)
let s:respectwildignore    = get(g:, 'filemanager_respectwildignore',    0)
let s:ignorecase           = get(g:, 'filemanager_ignorecase',          '')
let s:sortmethod           = get(g:, 'filemanager_sortmethod',      'name')
let s:sortfunc             = get(g:, 'filemanager_sortfunc',           'i')
let s:sortorder = get(g:, 'filemanager_sortorder', '/$,.*[^/]$,^\..*/$,^\..*[^/]$,\.bak$,^__pycache__/$,\.swp$,\~$')
let s:depthstr = '| '
let s:depthstrmarked = '++'


" Just <abuf> doesn't work. More autocmds in s:initialize() and elsewhere
aug filemanager
	au!
	au VimEnter           *  silent! au! FileExplorer
	au VimEnter,BufEnter  *  call s:enter(expand('<afile>:p'), str2nr(expand('<abuf>')))
	if s:usebookmarkfile
		au VimEnter   *  silent call s:bookmarkcmd('', 'load')
		au VimLeave   *  call s:bookmarkcmd('', 'write')
	endif
aug END


" Use the longer representation if your depthstr's have special characters
"let s:depthstrpat = '\(\V'.escape(s:depthstr, '\').'\m\|\V'.escape(s:depthstrmarked, '\').'\m\)'
let s:depthstrpat = '\('.s:depthstr.'\|'.s:depthstrmarked.'\)'
let s:depthstronlypat = '\('.s:depthstr.'\)'
let s:depthstrmarkedpat = '\('.s:depthstrmarked.'\)'
let s:filetypepat = '[\*@=|/]'
let s:separator = '/'  " Not file system separator (but coincides). See syntax conceal in s:initialize()

" Required to be able to move filemanager windows between tabs
let s:buflist = []

let s:bookmarks = {}
let s:bookmarkvars = ['treeroot', 'sortorder', 'sortmethod', 'sortreverse',
                     \'ignorecase','respectgitignore','showhidden',
		     \'orientation', 'filters', 'marked']
let s:bookmarknames = "'".'"0123456789qwertyuiopasdfghjklzxcvbnmQWERTYUIOPASDFGHJKLZXCVBNM[]{};:,.<>/?\!@#$%^&*()-_=+`~'
let s:bookmarknames = map(range(len(s:bookmarknames)), 's:bookmarknames[v:val]')
if s:usebookmarkfile
	if has('nvim')
		let s:bookmarkfile = stdpath('cache').'/filemanagerbookmarks'
	else
		let s:bookmarkfile = getenv('HOME').'/.vim/.filemanagerbookmarks'
	endif
else
	s:bookmarkfile = ''
endif
"}}}


" Directory listing {{{
fun! s:dirreadable(path)  " {{{
	return isdirectory(a:path) && !empty(glob(escape(fnameescape(a:path), '~').'/.', 1, 1, 1))
endfun  " }}}


fun! s:simplify(path)  " {{{
	" Vim's simplify() doesn't resolve symlink/..
	let l:split = split(simplify(a:path), '/..\(/\|$\)', 1)
	while len(l:split) > 1
		if getftype(l:split[0]) == 'link'
			let l:split[0] = fnamemodify(resolve(l:split[0]), ':h').'/'.remove(l:split, 1)
		else
			let l:split[0] .= '/'.remove(l:split, 1)
		endif
	endwhile
	if a:path[-1:-1] == '/' && l:split[0][-1:-1] != '/'
		let l:split[0] .= '/'
	elseif a:path[-1:-1] != '/' && l:split[0][-1:-1] == '/'
		let l:split[0] = l:split[0][:-2]
	endif
	return l:split[0]
endfun  " }}}


fun! s:getdircontents(path)  " {{{
	let l:path = escape(fnameescape(a:path), '~')
	let l:dic = {'': getftime(a:path)}
	let l:ignored = ['.', '..']
	if b:filemanager_respectgitignore
		let l:gitignored = systemlist('cd '.shellescape(a:path, 0).' && git check-ignore * .*')
		if !v:shell_error
			let l:ignored += l:gitignored
		endif
	endif
	let l:list = glob(l:path.'/*', !s:respectwildignore, 1, 1)
	if b:filemanager_showhidden
		let l:list += glob(l:path.'/.*', !s:respectwildignore, 1, 1)
	endif
	for l:item in l:list
		if isdirectory(l:item)
			let l:dic[fnamemodify(l:item, ':t')] = {}
		else
			let l:dic[fnamemodify(l:item, ':t')] = 0
		endif
	endfor
	" This was measured to be (slightly) faster at any length of l:ignored
	for l:ex in l:ignored
		if has_key(l:dic, l:ex)
			call remove(l:dic, l:ex)
		endif
	endfor
	return l:dic
endfun  " }}}


fun! s:sortbyname(list, path)  " {{{
	let l:matches = map(split(b:filemanager_sortorder, ','), '[]')
	let l:revsplitsortorder = reverse(split(b:filemanager_sortorder, ','))

	for l:name in a:list
		if getftype(a:path.'/'.l:name) == 'dir'
			let l:line = l:name.'/'  " No separator here
		else
			let l:line = l:name
		endif
		let l:i = 0
		for l:pattern in l:revsplitsortorder
			if match(l:line, '\C'.l:pattern) != -1
				let l:i = -l:i
				break
			endif
			let l:i += 1
		endfor
		call add(l:matches[l:i < 0 ? -l:i : 0], l:name)
	endfor

	let l:sorted = []
	for l:sublist in reverse(l:matches)
		let l:sorted += sort(l:sublist, s:sortfunc)
	endfor

	return l:sorted
endfun  " }}}


fun! s:sortbytime(list, path)  " {{{
	let l:list = map(a:list, 'getftime(a:path."/".v:val)." ".v:val')
	return map(reverse(sort(l:list, 'N')), 'substitute(v:val, "^-\\?\\d* ", "", "")')
endfun  " }}}


fun! s:sort(dic, path)  " {{{
	if b:filemanager_sortmethod == 'name'
		let l:sorted = s:sortbyname(keys(a:dic), a:path)
	elseif b:filemanager_sortmethod == 'time'
		let l:sorted = s:sortbytime(keys(a:dic), a:path)
	endif
	return b:filemanager_sortreverse ? reverse(l:sorted) : l:sorted
endfun  " }}}


fun! s:printcontents(dic, path, depth, linenr)  " {{{
	let l:path = substitute(a:path, '/$', '', '')
	let l:linenr = a:linenr

	for l:name in s:sort(a:dic, l:path)
		let l:ftype = getftype(l:path.'/'.l:name)
		if l:name == ''
			" This is where timestamps are stored
			if len(a:dic) > 1
				continue
			endif
			" Directory was empty
			let l:line = ''
		elseif l:ftype == 'dir'
			let l:line = l:name.s:separator.'/'
		elseif l:ftype == 'link'
			let l:line = l:name.s:separator.'@'
		elseif l:ftype == 'socket'
			let l:line = l:name.s:separator.'='
		elseif l:ftype == 'fifo'
			let l:line = l:name.s:separator.'|'
		else
			if executable(l:path.'/'.l:name)
				let l:line = l:name.s:separator.'*'
			else
				let l:line = l:name.s:separator
			endif
		endif

		if index(b:filemanager_marked, l:path.'/'.l:name) == -1
			let l:line = repeat(s:depthstr, a:depth).s:separator.l:line
		else
			let l:line = repeat(s:depthstrmarked, a:depth).s:separator.l:line
		endif

		call setline(l:linenr, l:line)
		let l:linenr += 1

		let l:contents = a:dic[l:name]
		if type(l:contents) == v:t_dict && !empty(l:contents)
			let l:linenr = s:printcontents(l:contents, l:path.'/'.l:name, a:depth+1, l:linenr)
		endif
	endfor

	return l:linenr
endfun  " }}}


fun! s:filtercontents(dic)  " {{{
	let l:filtered = {}
	for [l:name, l:contents] in items(a:dic)
		if type(l:contents) == v:t_dict && !empty(l:contents)
			let l:contents = s:filtercontents(l:contents)
			" No need to check if name matches when contents do
			if !empty(l:contents)
				let l:filtered[l:name] = l:contents
				continue
			endif
		endif
		let l:all = 1
		for l:pattern in b:filemanager_filters
			if match(l:name, b:filemanager_ignorecase.l:pattern) == -1
				let l:all = 0
				break
			endif
		endfor
		if l:all
			let l:filtered[l:name] = l:contents
		endif
	endfor
	return l:filtered
endfun  " }}}


fun! s:setbufname()  " {{{
	" Buffer number required for uniqueness
	let l:str = '[filemanager:'.bufnr().(b:filemanager_auxiliary ? ':AUX' : '')
	let l:str .= (exists('b:filemanager_renamefrom') ? ':RENAME' : '').']'
	silent exe 'file '.fnameescape(l:str.' '.substitute(b:filemanager_treeroot, '/$', '', '').'/')
endfun  " }}}


fun! s:printtree()  " {{{
	setl modifiable noreadonly
	silent %delete _
	call setline(1, '..'.s:separator.'/')
	call setline(2, fnamemodify(b:filemanager_treeroot, ':t').s:separator.'/')
	if empty(b:filemanager_filters)
		call s:printcontents(b:filemanager_tree, b:filemanager_treeroot, 1, 3)
	else
		call s:printcontents(s:filtercontents(b:filemanager_tree), b:filemanager_treeroot, 1, 3)
	endif
	setl nomodifiable readonly nomodified
	if !b:filemanager_auxiliary
		if s:dirreadable(b:filemanager_treeroot)
			exe 'tcd '.fnameescape(b:filemanager_treeroot)
		else
			echo 'Permission denied'
		endif
	endif
	call s:setbufname()

	if s:notifyoffilters && !empty(b:filemanager_filters)
		echo 'Filters active'
	endif
endfun  " }}}


fun! s:undercursor(linenr=-1, lines=0)  " {{{
	let l:linenr = a:linenr < 0 ? line('.') : a:linenr

	if l:linenr == 1 && type(a:lines) != v:t_list
		return fnamemodify(b:filemanager_treeroot, ':h')
	elseif l:linenr == 2 && type(a:lines) != v:t_list
		return b:filemanager_treeroot
	endif

	let l:line = type(a:lines) == v:t_list ? a:lines[l:linenr] : getline(l:linenr)
	let l:nodepth = substitute(l:line, '^'.s:depthstrpat.'*'.s:separator, '', '')
	let l:path = [substitute(l:nodepth, s:separator.s:filetypepat.'\?$', '', '')]
	let l:depth = len(l:line) - len(l:nodepth)

	while l:depth > len(s:depthstr.s:separator)
		let l:linenr -= 1
		let l:line = type(a:lines) == v:t_list ? a:lines[l:linenr] : getline(l:linenr)
		let l:nodepth = substitute(l:line, '^'.s:depthstrpat.'*'.s:separator, '', '')
		let l:otherdepth = len(l:line) - len(l:nodepth)

		if l:depth > l:otherdepth
			call insert(l:path, substitute(l:nodepth, s:separator.s:filetypepat.'\?$', '', ''))
			let l:depth = l:otherdepth
		endif
	endwhile

	return substitute(b:filemanager_treeroot, '/$', '', '').'/'.join(l:path, '/')
endfun  " }}}


fun! s:movecursorbypath(path)  " {{{
	let l:list = split(a:path[len(b:filemanager_treeroot):], '/')
	if empty(l:list)
		call cursor(2, 1)
		return
	endif
	let l:depth = 0
	let l:linenr = 2
	let l:lastnr = line('$')
	for l:name in l:list
		let l:linenr += 1
		let l:depth += 1
		while 1
			let l:line = getline(l:linenr)
			if match(l:line, '\C^'.s:depthstrpat.'\{'.l:depth.'}'.s:separator.'\V'.escape(l:name, '\').'\m'.s:separator.s:filetypepat.'\?$') != -1
				break
			endif
			let l:linenr += 1
			if match(l:line, '\C^'.s:depthstrpat.'\{'.l:depth.'}') == -1 || l:linenr > l:lastnr
				echo 'Path not visible or non-existent: "'.a:path.'"'
				return
			endif
		endwhile
	endfor
	let l:linenr += (a:path[-1:-1] == '/')
	call cursor(l:linenr, 0)
endfun  " }}}


fun! s:toggledir(path, operation)  " {{{
	" operation: 0 = toggle, 1 = fold, 2 = unfold
	if a:operation == 0 && line('.') == 1
		call s:parentdir()
		return 0
	elseif a:operation == 0 && line('.') == 2
		call s:refreshtree(1)
		return 0
	endif

	let l:list = split(a:path[len(b:filemanager_treeroot):], '/')

	if a:operation != 2 && empty(l:list)
		echo 'Cannot fold the whole tree'
		return 1
	endif

	let l:dic = b:filemanager_tree
	for l:name in l:list
		let l:dic = get(l:dic, l:name, 0)
		if type(l:dic) != v:t_dict
			echo '"'.a:path.'" is not a directory'
			return 1
		endif
	endfor

	if empty(l:dic)
		if a:operation == 1
			" Currently unreachable (see s:folddir())
			echo 'Already folded'
			return 1
		endif
		call extend(l:dic, s:getdircontents(a:path))
	else
		if a:operation == 2
			echo 'Nothing to unfold'
			return 1
		endif
		call filter(l:dic, 0)
	endif

	let l:winview = winsaveview()
	call s:printtree()
	call winrestview(l:winview)
	return 0
endfun  " }}}


fun! s:folddir(path, recursively)  " {{{
	if a:recursively
		let l:path = split(a:path[len(b:filemanager_treeroot):], '/')
		if len(l:path) < 2
			let l:path = b:filemanager_treeroot
		else
			let l:path = b:filemanager_treeroot.'/'.l:path[0]
		endif
	else
		let l:path = fnamemodify(a:path, ':h')
	endif
	if !s:toggledir(l:path, 1)
		call s:movecursorbypath(l:path)
	endif
endfun  " }}}


fun! s:descenddir(path, onlyone)  " {{{
	if a:path[:len(b:filemanager_treeroot)-1] != b:filemanager_treeroot
	   \ && a:path != fnamemodify(b:filemanager_treeroot, ':h')
		" Happens when the user tries to s:openbyname() by abs. path
		echo 'Directory out of reach: "'.a:path.'"'
		return
	endif
	let l:list = split(a:path[len(b:filemanager_treeroot):], '/')
	if empty(l:list)
		echo 'Unable to descend upwards'
		return
	endif
	if !isdirectory(a:path)
		call remove(l:list, -1)
	endif
	if empty(l:list)
		echo 'Nowhere to descend'
		return
	endif
	if a:onlyone
		let l:list = l:list[0:0]
	endif

	for l:name in l:list
		" Happens when s:openbyname() a deep not visible directory
		if !has_key(b:filemanager_tree, l:name)
			let b:filemanager_tree = s:getdircontents(a:path)
			break
		endif
		let b:filemanager_tree = b:filemanager_tree[l:name]
	endfor
	let b:filemanager_treeroot = substitute(b:filemanager_treeroot, '/$', '', '').'/'.join(list, '/')
	if empty(b:filemanager_tree)
		let b:filemanager_tree = s:getdircontents(b:filemanager_treeroot)
	endif

	call s:printtree()
	call s:movecursorbypath(a:path)
endfun  " }}}


fun! s:parentdir()  " {{{
	let newroot = fnamemodify(b:filemanager_treeroot, ':h')
	if b:filemanager_treeroot ==# l:newroot
		echo 'Already in the uppermost directory'
		return
	endif
	let l:path = s:undercursor(line('.') > 2 ? line('.') : 2)
	let l:oldtree = b:filemanager_tree
	let l:oldrootname = fnamemodify(b:filemanager_treeroot, ':t')
	let b:filemanager_treeroot = l:newroot
	let b:filemanager_tree = s:getdircontents(b:filemanager_treeroot)
	if type(get(b:filemanager_tree, l:oldrootname, 0)) == v:t_dict
		let b:filemanager_tree[l:oldrootname] = l:oldtree
	endif
	call s:printtree()
	call s:movecursorbypath(l:path)
endfun  " }}}


fun! s:refreshcontents(dic, path, force)  " {{{
	if !a:force && getftime(a:path) == a:dic['']
		let l:anyupdated = 0
		for [l:name, l:contents] in items(a:dic)
			if type(l:contents) == v:t_dict && !empty(l:contents)
				let [l:updated, a:dic[l:name]] = s:refreshcontents(l:contents, a:path.'/'.l:name, a:force)
				if l:updated
					let l:anyupdated = 1
				endif
			endif
		endfor
		return [l:anyupdated, a:dic]
	endif
	let l:newtree = s:getdircontents(a:path)
	for l:name in keys(l:newtree)
		let l:contents = get(a:dic, l:name, 0)
		if type(l:contents) == v:t_dict && !empty(l:contents)
			let l:newtree[l:name] = s:refreshcontents(l:contents, a:path.'/'.l:name, a:force)[1]
		endif
	endfor
	return [1, l:newtree]
endfun  " }}}


fun! s:refreshtree(force)  " {{{
	let l:refreshed = s:refreshcontents(b:filemanager_tree, b:filemanager_treeroot, a:force > 0)
	if l:refreshed[0] == 0
		if a:force < 0
			let l:winview = winsaveview()
			call s:printtree()
			call winrestview(l:winview)
		endif
		return
	endif
	" simplify() required only after renaming by tree
	let l:path = s:simplify(s:undercursor())
	let b:filemanager_tree = l:refreshed[1]
	let l:winview = winsaveview()
	call s:printtree()
	call winrestview(l:winview)
	if l:path[:len(b:filemanager_treeroot)-1] == b:filemanager_treeroot
		call s:movecursorbypath(l:path)
	endif
endfun  " }}}


fun! s:movetreecontents(from, to)  " {{{
	let l:to = s:simplify(a:to)
	if l:to[:len(b:filemanager_treeroot)-1] != b:filemanager_treeroot
		return
	endif
	let l:dicfrom = b:filemanager_tree
	let l:split = split(a:from[len(b:filemanager_treeroot):], '/')
	for l:name in l:split[:-2]
		let l:dicfrom = l:dicfrom[l:name]
	endfor
	let l:namefrom = l:split[-1]
	let l:dicto = b:filemanager_tree
	let l:split = split(l:to[len(b:filemanager_treeroot):], '/')
	for l:name in l:split[:-2]
		if !has_key(l:dicto, l:name)
			return
		endif
		let l:dicto = l:dicto[l:name]
	endfor
	let l:dicto[l:split[-1]] = remove(l:dicfrom, l:namefrom)
endfun  " }}}


fun! s:toggleshowhidden()  " {{{
	let b:filemanager_showhidden = !b:filemanager_showhidden
	call s:refreshtree(1)
	echo 'Show hidden '.(b:filemanager_showhidden ? 'ON' : 'OFF')
endfun  " }}}


fun! s:setignorecase()  " {{{
	let l:choice = confirm("Configure ignore case in Filter and Mark:", "&Obey 'ignorecase'\n&Ignore\n&Don't ignore")
	if l:choice == 0
		return
	else
		let b:filemanager_ignorecase = ['', '\c', '\C'][l:choice-1]
	endif
	let l:path = s:undercursor()
	let l:winview = winsaveview()
	call s:printtree()
	call winrestview(l:winview)
	call s:movecursorbypath(l:path)
endfun  " }}}


fun! s:togglerespectgitignore()  " {{{
	let b:filemanager_respectgitignore = !b:filemanager_respectgitignore
	call s:refreshtree(1)
	echo 'Respect .gitignore '.(b:filemanager_respectgitignore ? 'ON' : 'OFF')
endfun  " }}}


fun! s:togglesortreverse()  " {{{
	let b:filemanager_sortreverse = !b:filemanager_sortreverse
	let l:path = s:undercursor()
	let l:winview = winsaveview()
	call s:printtree()
	call winrestview(l:winview)
	call s:movecursorbypath(l:path)
	echo 'Reverse sort order '.(b:filemanager_sortreverse ? 'ON' : 'OFF')
endfun  " }}}


fun! s:setsortmethod()  " {{{
	let l:choice = confirm("Set sort method:", "By &name\nBy &time")
	if l:choice == 0
		return
	else
		let b:filemanager_sortmethod = ['name', 'time'][l:choice-1]
	endif
	let l:path = s:undercursor()
	let l:winview = winsaveview()
	call s:printtree()
	call winrestview(l:winview)
	call s:movecursorbypath(l:path)
endfun  " }}}


fun! s:setsortorder()  " {{{
	call inputsave()
	echo 'Current sort order:  "'.b:filemanager_sortorder.'"'
	let l:sortorder = input('Enter new sort order: ', b:filemanager_sortorder)
	call inputrestore()
	redraw
	if l:sortorder == ''
		echo 'Empty string supplied. Default sort order set'
		let l:sortorder = s:sortorder
	endif
	let b:filemanager_sortorder = l:sortorder
	let l:path = s:undercursor()
	let l:winview = winsaveview()
	call s:printtree()
	call winrestview(l:winview)
	call s:movecursorbypath(l:path)
endfun  " }}}


fun! s:filter(pattern, bang)  " {{{
	if a:bang == '!'
		let b:filemanager_filters = []
	endif

	if a:pattern == ''
		if !empty(b:filemanager_filters)
			call remove(b:filemanager_filters, -1)
		endif
	else
		call add(b:filemanager_filters, a:pattern)
	endif

	call s:printtree()
	call cursor(2, 1)
	if empty(b:filemanager_filters)
		echo 'All filters removed'
	endif
endfun  " }}}


fun! s:opendirs(tree, relpath)  " {{{
	let l:list = []
	for [l:name, l:contents] in items(a:tree)
		if type(l:contents) == v:t_dict && !empty(l:contents)
			call add(l:list, a:relpath.l:name)
			let l:list += s:opendirs(l:contents, a:relpath.l:name.'/')
		endif
	endfor
	return l:list
endfun  " }}}


fun! s:bookmarksave(name, bak)  " {{{
	if !a:bak && a:name == s:bookmarknames[0]
		call s:bookmarkbackup(bufnr())
		let s:bookmarks[a:name][0] = 0
	else
		let s:bookmarks[a:name] = map(copy(s:bookmarkvars), 'eval("b:filemanager_".v:val)')
		call insert(s:bookmarks[a:name], s:opendirs(b:filemanager_tree, ''))
		call insert(s:bookmarks[a:name], s:undercursor())
		call insert(s:bookmarks[a:name], a:bak)
	endif
endfun  " }}}


fun! s:bookmarkbackup(bufnr)  " {{{
	if exists('b:filemanager_changedticksave') && b:filemanager_changedticksave == b:changedtick
		return
	endif
	let l:shift = []
	for l:name in s:bookmarknames
		if has_key(s:bookmarks, l:name)
			if s:bookmarks[l:name][0]
				call insert(l:shift, l:name)
			endif
		else
			call insert(l:shift, l:name)
			break
		endif
	endfor
	while len(l:shift) > 1
		let s:bookmarks[l:shift[0]] = s:bookmarks[l:shift[1]]
		call remove(l:shift, 0)
	endwhile
	call win_execute(bufwinid(a:bufnr), 'call s:bookmarksave(l:shift[0], 1)')
endfun  " }}}


fun! s:bookmarkrestore(name)  " {{{
	if !has_key(s:bookmarks, a:name)
		echo 'No bookmark "'.a:name.'" saved'
		return
	endif
	let l:bookmark = s:bookmarks[a:name]
	call s:bookmarkbackup(bufnr())
	let l:i = 3
	for l:var in s:bookmarkvars
		exe 'let b:filemanager_'.l:var.' = l:bookmark[l:i]'
		let l:i += 1
	endfor
	let b:filemanager_tree = s:getdircontents(b:filemanager_treeroot)
	for l:path in l:bookmark[2]
		call s:toggledir(b:filemanager_treeroot.'/'.l:path, 2)
	endfor
	call s:printtree()
	call s:movecursorbypath(l:bookmark[1])
	let b:filemanager_changedticksave = b:changedtick
endfun  " }}}


fun! s:printbookmarks()  " {{{
	if empty(s:bookmarks)
		echo 'No bookmarks saved'
		return
	else
		echo 'Bookmarks:'
	endif
	let l:i = index(s:bookmarkvars, 'treeroot') + 3
	for l:name in filter(copy(s:bookmarknames), 'has_key(s:bookmarks, v:val)')
		echo (s:bookmarks[l:name][0] ? 'bak ' : '    ').l:name.': '.s:bookmarks[l:name][l:i]
		for l:path in s:bookmarks[l:name][2]
			echo '         '.l:path
		endfor
	endfor
endfun  " }}}


fun! s:bookmarkcmd(bang, arg)  " {{{
	if a:arg == 'write' && !empty(s:bookmarkfile)
		if s:writebackupbookmarks
			let l:bookmarks = s:bookmarks
		else
			let l:bookmarks = filter(copy(s:bookmarks), '!v:val[0]')
		endif
		if filereadable(s:bookmarkfile)
			let l:saved = readfile(s:bookmarkfile)
			if empty(l:saved) || empty(l:saved[0]) || empty(eval(l:saved[0]))
				let l:saved = l:bookmarks
			else
				let l:saved = eval(l:saved[0])
				call extend(l:saved, l:bookmarks)
			endif
		else
			let l:saved = l:bookmarks
		endif
		if writefile([string(l:saved)], s:bookmarkfile)
			echo 'Failed to write bookmarks to file'
		endif
	elseif a:arg == 'load' && !empty(s:bookmarkfile)
		if !filereadable(s:bookmarkfile)
			echo 'Bookmark file not readable or non-existent'
		else
			let l:saved = readfile(s:bookmarkfile)
			if empty(l:saved) || empty(l:saved[0]) || empty(eval(l:saved[0]))
				echo 'Bookmark file empty'
			else
				call extend(s:bookmarks, eval(l:saved[0]))
			endif
		endif
	elseif a:bang == '!' && a:arg != ''
		if index(s:bookmarknames, a:arg) == -1
			echo 'Invalid bookmark name "'.a:arg.'"'
		else
			call s:bookmarksave(a:arg, 0)
		endif
	elseif a:arg != ''
		if index(s:bookmarknames, a:arg) == -1
			echo 'Invalid bookmark name "'.a:arg.'"'
		else
			call s:bookmarkrestore(a:arg)
		endif
	else
		call s:printbookmarks()
	endif
endfun  " }}}


fun! s:bookmarkdel(bang, name)  " {{{
	if a:name == 'file' && a:bang == '!'
		call s:bookmarkdel(a:bang, '')
		call s;bookmarkdel('', a:name)
		return
	endif
	if a:name == 'file' && !empty(s:bookmarkfile)
		if empty(glob(escape(fnameescape(s:bookmarkfile), '~'), 1, 1, 1))
			echo 'Bookmark file non-existent'
		elseif confirm("Delete bookmark file?", "&No\n&Yes") == 2 && delete(s:bookmarkfile)
			echo 'Failed to delete bookmark file'
		endif
	elseif a:name != ''
		if index(s:bookmarknames, a:name) == -1
			echo 'Invalid bookmark name "'.a:name.'"'
			return
		elseif !has_key(s:bookmarks, a:name)
			echo 'No bookmark "'.a:name.'" saved'
		else
			call remove(s:bookmarks, a:name)
		endif
		if a:bang == '!' && !empty(s:bookmarkfile)
			let l:bookmarkssave = s:bookmarks
			let s:bookmarks = {}
			call s:bookmarkcmd('', 'load')
			if empty(s:bookmarks)
				let s:bookmarks = l:bookmarkssave
				return
			endif
			if has_key(s:bookmarks, a:name)
				call remove(s:bookmarks, a:name)
				if writefile([string(s:bookmarks)], s:bookmarkfile)
					echo 'Failed to write updated bookmarks to file'
				endif
			else
				echo 'No bookmark "'.a:name.'" saved in file'
			endif
			let s:bookmarks = l:bookmarkssave
		endif
	elseif a:bang == '!'
		if empty(s:bookmarks)
			echo 'No bookmarks saved'
		elseif confirm("Delete all bookmarks?", "&No\n&Yes") == 2
			call filter(s:bookmarks, 0)
		endif
	endif
endfun  " }}}
" }}}


" File operations {{{
fun! s:newdir()  " {{{
	let l:path = fnamemodify(s:undercursor(line('.') > 3 ? line('.') : 3), ':h')
	if s:dirreadable(l:path)
		exe 'lcd '.fnameescape(l:path)
	endif
	call inputsave()
	let l:name = input('Enter new directory name: ', '', 'file')
	call inputrestore()
	redraw
	if l:name == ''
		echo 'Empty name supplied. Aborted'
		return
	endif

	let l:path = s:simplify(substitute(l:path, '/$', '', '').'/'.l:name)
	if !empty(glob(escape(fnameescape(l:path), '~'), 1, 1, 1))
		echo 'Path exists: "'.l:path.'"'
		return
	endif

	let l:cmp = b:filemanager_treeroot == '/' ? '/' : b:filemanager_treeroot.'/'
	let l:choice = 0
	if l:path[:len(l:cmp)-1] != l:cmp
		let l:choice = confirm("Create directory outside the current tree?", "&No\n&Yes")
		if l:choice != 2
			return
		endif
	endif
	try
		call mkdir(l:path)
	catch /^Vim\%((\a\+)\)\=:E739/
		echo 'Failed to create directory: "'.l:path.'"'
		return
	endtry
	if l:choice
		return
	endif
	let l:name = l:path[len(l:cmp):]
	let l:path = l:cmp
	call s:refreshtree(0)
	for l:dir in split(l:name, '/')
		" Don't notify if already open
		silent call s:toggledir(l:path.l:dir, 2)
		let l:path .= l:dir.'/'
	endfor
	call s:movecursorbypath(l:path)
endfun  " }}}


fun! s:openbyname()  " {{{
	let l:path = fnamemodify(s:undercursor(line('.') > 3 ? line('.') : 3), ':h')
	if s:dirreadable(l:path)
		exe 'lcd '.fnameescape(l:path)
	endif
	call inputsave()
	let l:name = input('Enter file/directory name: ', '', 'file')
	call inputrestore()
	redraw
	if l:name == ''
		echo 'Empty name supplied. Aborted'
		return
	endif

	let l:substring = matchstr(l:name, '^\s*\~[^/]*/')
	let l:name = substitute(l:name, '^\s*\~[^/]*/', expandcmd(l:substring), '')
	if l:name[0] != '/'
		let l:name = substitute(l:path, '/$', '', '').'/'.l:name
	endif

	call s:open(s:simplify(l:name), -1)
endfun  " }}}


fun! s:open(path, mode)  " {{{
	if isdirectory(a:path)
		if a:mode == 0
			call s:toggledir(a:path, 0)
			return
		elseif a:mode == -1
			call s:descenddir(a:path, 0)
			return
		elseif a:mode == 4
			" Allow opening in a new tab
		else
			echo '"'.a:path.'" is a directory'
			return
		endif
	" Don't list missing symlinks, otherwise they are always not readable
	elseif !empty(glob(escape(fnameescape(a:path), '~'), 1, 1, 0)) && !filereadable(a:path)
		echo '"'.a:path.'" is not readable'
		return
	endif

	if b:filemanager_auxiliary
		exe 'edit '.fnameescape(a:path)
		return
	endif

	if a:mode == 0 || a:mode == -1  " <enter> or by name: in previous
		if winnr('#') == 0 || winnr('#') == winnr()
			call s:open(a:path, b:filemanager_orientation == 1 ? 1 : 2)
			return
		endif
		silent wincmd p
		exe 'confirm edit '.fnameescape(a:path)
	elseif a:mode == 1  " single vertical window
		confirm wincmd o
		exe 'new '.fnameescape(a:path)
		exe 'wincmd '.(s:preferleft ? 'L' : 'H')
		exe 'vertical resize '.((100 - s:winsize) * &columns / 100)
	elseif a:mode == 2  " single horizontal window
		confirm wincmd o
		exe 'new '.fnameescape(a:path)
		exe 'wincmd '.(s:preferbelow ? 'K' : 'J')
		exe 'resize '.((100 - s:winsize) * &lines / 100)
	elseif a:mode == 3  " above/below all and maximized
		exe 'new '.fnameescape(a:path)
		exe 'wincmd '.(s:preferbelow ? 'K' : 'J')
		wincmd _
	elseif a:mode == 4  " new tab
		exe 'tab new '.fnameescape(a:path)
	elseif a:mode == 5  " new split on the side
		let l:winview = winsaveview()
		exe 'new '.fnameescape(a:path)
		exe 'wincmd '.(s:preferbelow ? 'K' : 'J')
		silent wincmd p
		exe 'wincmd '.(s:preferleft ? 'H' : 'L')
		exe 'vertical resize '.(s:winsize * &columns / 100)
		call winrestview(l:winview)
		silent wincmd p
	elseif a:mode == 6  " replace filemanager window
		exe 'edit '.fnameescape(a:path)
	endif
endfun  " }}}


fun! s:openterminal(undercursor)  " {{{
	if a:undercursor
		let l:path = fnamemodify(s:undercursor(line('.') > 3 ? line('.') : 3), ':h')
	else
		let l:path = b:filemanager_treeroot
	endif
	if s:dirreadable(l:path)
		exe 'lcd '.fnameescape(l:path)
	endif

	let l:vertical = b:filemanager_orientation
	confirm wincmd o
	if has('nvim')
		new
	endif
	terminal
	if l:vertical
		exe 'wincmd '.(s:preferleft ? 'L' : 'H')
		exe 'vertical resize '.((100 - s:winsize) * &columns / 100)
	else
		exe 'wincmd '.(s:preferbelow ? 'K' : 'J')
		exe 'resize '.((100 - s:winsize) * &lines / 100)
	endif
endfun  " }}}


fun! s:namematches(tree, path, pattern) abort  " {{{
	let l:list = []
	for [l:name, l:contents] in items(filter(copy(a:tree), 'v:key != ""'))
		if match(l:name, b:filemanager_ignorecase.a:pattern) != -1
			call add(l:list, a:path.'/'.l:name)
		endif
		if type(l:contents) == v:t_dict && !empty(l:contents)
			let l:list += s:namematches(l:contents, a:path.'/'.l:name, a:pattern)
		endif
	endfor
	return l:list
endfun  " }}}


fun! s:markbypat(pattern, bang)  " {{{
	if a:bang == '!'
		let l:i = 0
		for l:path in b:filemanager_marked
			if match(fnamemodify(l:path, ':t'), b:filemanager_ignorecase.a:pattern) != -1
				call remove(b:filemanager_marked, l:i)
			else
				let l:i += 1
			endif
		endfor
	else
		for l:path in s:namematches(b:filemanager_tree, substitute(b:filemanager_treeroot, '/$', '', ''), a:pattern)
			if index(b:filemanager_marked, l:path) == -1
				call add(b:filemanager_marked, l:path)
			endif
		endfor
	endif
	let l:winview = winsaveview()
	call s:printtree()
	call winrestview(l:winview)
endfun  " }}}


fun! s:mark(rangeends)  " {{{
	let l:presentpaths = []
	let l:newpaths = []
	for l:linenr in range(min(a:rangeends), max(a:rangeends))
		let l:path = substitute(s:undercursor(l:linenr), '[^/]\zs/$', '', '')
		if l:linenr < 3
			echo 'Skipping "'.l:path.'"'
			continue
		endif
		let l:i = index(b:filemanager_marked, l:path)
		if l:i == -1
			call add(l:newpaths, l:path)
		else
			call add(l:presentpaths, l:i)
		endif
	endfor
	if empty(l:newpaths)
		for l:i in reverse(sort(l:presentpaths, 'n'))
			call remove(b:filemanager_marked, l:i)
		endfor
	else
		let b:filemanager_marked += l:newpaths
	endif
	let l:winview = winsaveview()
	call s:printtree()
	call winrestview(l:winview)
endfun  " }}}


fun! s:unmarkall()  " {{{
	call filter(b:filemanager_marked, 0)
	let l:winview = winsaveview()
	call s:printtree()
	call winrestview(l:winview)
endfun  " }}}


fun! s:cmdonmarked(step)  " {{{
	if a:step == 0
		echo 'Marked:'
		if empty(b:filemanager_marked)
			echo ' '.substitute(s:undercursor(), '[^/]\zs/$', '', '')
		else
			call sort(b:filemanager_marked, s:sortfunc)
			for l:path in b:filemanager_marked
				echo ' '.l:path
			endfor
		endif
		echo 'Use "..." to place them in the middle and "\..." to insert "..."'

		cnoremap <buffer>  <cr>  <c-\>e<sid>cmdonmarked(1)<cr><cr>
		au filemanager CmdlineLeave <buffer> ++once cunmap <buffer> <cr>
		return
	endif

	" Has to be here because the user may exit cmdline without executing
	if empty(b:filemanager_marked)
		let l:marked = ' '.shellescape(substitute(s:undercursor(), '[^/]\zs/$', '', ''), 1).' '
	else
		au filemanager ShellCmdPost <buffer> ++once if !v:shell_error | call filter(b:filemanager_marked, 0) | endif
		let l:marked = ' '.join(map(copy(b:filemanager_marked), 'shellescape(v:val, 1)'), ' ').' '
	endif
	au filemanager ShellCmdPost <buffer> ++once call s:refreshtree(-1)

	let l:split = split(getcmdline(), '[^\\]\zs\.\.\.')
	call map(l:split, 'substitute(v:val, "\\\\\.\.\.", "...", "g")')
	if len(l:split) == 1
		return l:split[0].l:marked
	else
		return join(l:split, l:marked)
	endif
endfun  " }}}


fun! s:deletemarked()  " {{{
	let l:unmark = 0
	if empty(b:filemanager_marked)
		call add(b:filemanager_marked, substitute(s:undercursor(), '[^/]\zs/$', '', ''))
		let l:unmark = 1
	endif
	call sort(b:filemanager_marked, s:sortfunc)

	" Always faster than two filters
	let l:files = []
	let l:dirs = []
	for l:path in b:filemanager_marked
		call add(getftype(l:path) == 'dir' ? l:dirs : l:files, l:path)
	endfor

	if !empty(l:files)
		echo 'Files to delete:'
		for l:path in l:files
			echo ' '.l:path
		endfor
		if confirm("Delete printed files?", "&No\n&Yes") < 2
			echo 'Files not deleted'
		else
			for l:path in l:files
				if delete(l:path)
					echo 'Failed to delete "'.l:path.'"'
				elseif !l:unmark
					let l:unmark = 1
				endif
			endfor
		endif
	endif

	if !empty(l:dirs)
		echo 'Directories to delete:'
		for l:path in l:dirs
			echo ' '.l:path
		endfor
		let l:choice = confirm("Delete printed directories?", "&No\n&Empty only\n&All")
		if l:choice < 2
			echo 'Directories not deleted'
		else
			let l:choice = l:choice == 2 ? 'd' : 'rf'
			" Sort without s:sortfunc here: child dirs first
			for l:path in reverse(sort(l:dirs))
				if delete(l:path, l:choice)
					echo 'Failed to delete "'.l:path.'"'
				elseif !l:unmark
					let l:unmark = 1
				endif
			endfor
		endif
	endif

	if l:unmark
		call filter(b:filemanager_marked, 0)
		" Don't notify if path is not found (deleted)
		silent call s:refreshtree(-1)
	endif
endfun  " }}}


fun! s:renamemarked()  " {{{
	let l:unmark = 0
	if empty(b:filemanager_marked)
		call add(b:filemanager_marked, substitute(s:undercursor(), '[^/]\zs/$', '', ''))
		let l:unmark = 1
	endif

	let l:cmp = b:filemanager_treeroot == '/' ? '/' : b:filemanager_treeroot.'/'
	if len(b:filemanager_marked) == 1
		if b:filemanager_marked[0][:len(l:cmp)-1] != l:cmp
			echo 'Unable to rename "'.b:filemanager_marked[0].'": outside the current tree'
			if l:unmark
				call filter(b:filemanager_marked, 0)
			endif
			return
		endif
		exe 'lcd '.fnameescape(fnamemodify(b:filemanager_marked[0], ':h'))
		echo 'Current name: '.b:filemanager_marked[0]
		call inputsave()
		let l:destination = input('Enter new name: ', fnamemodify(b:filemanager_marked[0], ':t'), 'file')
		call inputrestore()
		redraw
		if l:destination == ''
			echo 'Empty name supplied. Aborted'
			if l:unmark
				call filter(b:filemanager_marked, 0)
			endif
		else
			let l:destination = s:simplify(substitute(fnamemodify(b:filemanager_marked[0], ':h'), '/$', '', '').'/'.l:destination)
			let l:err = s:renamebylist(b:filemanager_marked, [l:destination])
			if l:unmark
				call filter(b:filemanager_marked, 0)
			endif
			" Probably renaming the file under the cursor
			silent call s:refreshtree(0)
			if !l:err && l:destination[:len(b:filemanager_treeroot)-1] == b:filemanager_treeroot
				silent call s:movecursorbypath(l:destination)
			endif
		endif
		return
	endif

	let l:marked = []
	for l:path in sort(b:filemanager_marked)
		if l:path[:len(l:cmp)-1] == l:cmp
			call add(l:marked, l:path[len(b:filemanager_treeroot):])
		else
			echo 'Ignoring "'.l:path.'"'
		endif
	endfor

	let l:markedtree = {}
	for l:path in l:marked
		let l:dic = l:markedtree
		for l:dir in split(l:path, '/')[:-2]
			if type(get(l:dic, l:dir, 0)) != v:t_dict
				let l:dic[l:dir] = {'': 0}
			endif
			let l:dic = l:dic[l:dir]
		endfor
		call extend(l:dic, {fnamemodify(l:path, ':t'): 0}, 'keep')
	endfor

	if empty(l:markedtree)
		echo 'Nothing marked in current tree'
		return
	endif

	call s:renametree(l:markedtree)
endfun  " }}}


fun! s:renametree(tree=0)  " {{{
	if type(a:tree) != v:t_dict && s:undercursor(3) == substitute(b:filemanager_treeroot, '/$', '', '').'/'
		echo 'Cannot rename empty tree'
		return
	endif
	setl modifiable noreadonly
	call setline(1, "Edit and hit Enter to rename or Esc to abort. Don't reorder lines or change NonText")
	if type(a:tree) == v:t_dict
		silent 3,$delete _
		let l:markedsave = b:filemanager_marked
		let b:filemanager_marked = []
		call s:printcontents(a:tree, b:filemanager_treeroot, 1, 3)
		let b:filemanager_marked = l:markedsave
		call cursor(3, len(s:depthstr.s:separator) + 1)
	else
		let l:nodepth = substitute(getline('.'), '^'.s:depthstrpat.'*'.s:separator, '', '')
		let l:colnr = len(getline('.')) - len(l:nodepth) + 1
		if l:colnr > col('.')
			call cursor(0, l:colnr)
		endif
	endif

	let b:filemanager_renamefrom = getline(3, '$')
	call s:setbufname()

	delcommand Mark
	delcommand Filter
	delcommand Bookmark
	delcommand Delbookmark
	mapclear <buffer>
	nnoremap <buffer>  <cr>   <cmd>call <sid>renamefinish(1)<cr>
	inoremap <buffer>  <cr>   <esc><cmd>call <sid>renamefinish(1)<cr>
	nnoremap <buffer>  <esc>  <cmd>call <sid>renamefinish(0)<cr>
	au filemanager BufLeave <buffer> ++once call s:renamefinish(-1)
	let &timeout = s:timeoutsave
	setl undolevels=-123456  " Based on :help 'undolevels'
endfun  " }}}


fun! s:renamefinish(do)  " {{{
	if a:do > 0
		if line('$') - 2 != len(b:filemanager_renamefrom)
			echo 'Number of lines changed. Aborted'
			call s:renamefinish(0)
			return
		endif
		let l:changed = filter(range(3, line('$')), 'b:filemanager_renamefrom[v:val-3] !=# getline(v:val)')
		if empty(l:changed)
			echo 'Nothing to rename'
			call s:renamefinish(0)
			return
		endif
		let l:renameto = map(copy(l:changed), 's:undercursor(v:val)')
		let l:renamefrom = map(copy(l:changed), 's:undercursor(v:val - 3, b:filemanager_renamefrom)')
		call s:renamebylist(l:renamefrom, l:renameto)
	endif

	if exists('b:filemanager_renamefrom')
		unlet b:filemanager_renamefrom
		if a:do >= 0
			set notimeout
		endif
		mapclear <buffer>
		setl nomodifiable readonly undolevels=-1
		call s:definemapcmd()
		call s:refreshtree(-1)
	endif
endfun  " }}}


fun! s:renamebylist(listfrom, listto)  " {{{
	let l:existing = filter(copy(a:listto), '!empty(glob(escape(fnameescape(v:val), "~"), 1, 1, 1))')
	if !empty(l:existing)
		echo 'Destinations already exist:'
		for l:path in l:existing
			echo ' '.l:path
		endfor
		if confirm("Overwrite?", "&No\n&Yes") < 2
			echo 'Nothing moved'
			return 1
		endif
	endif

	let l:unmark = 0
	for l:i in range(len(a:listfrom))
		if rename(a:listfrom[l:i], a:listto[l:i])
			echo 'Failed to move "'.a:listfrom[l:i].'" to "'.a:listto[l:i].'"'
			continue
		elseif !l:unmark
			let l:unmark = 1
		endif
		if isdirectory(a:listto[l:i])
			" \= is simpler than doing all the escape() and hope
			let l:subwith = a:listto[l:i].'/'
			for l:j in range(l:i+1, len(a:listfrom)-1)
				let a:listfrom[l:j] = substitute(a:listfrom[l:j], '^\V'.escape(a:listfrom[l:i], '\').'/', '\=l:subwith', '')
			endfor
			call s:movetreecontents(a:listfrom[l:i], a:listto[l:i])
		endif
	endfor

	if l:unmark
		call filter(b:filemanager_marked, 0)
	endif
	return !l:unmark
endfun  " }}}


fun! s:openexternal(path)  " {{{
	silent let l:output = system('setsid -f '.s:opencmd.' '.shellescape(a:path, 0).' </dev/null >/dev/null 2>&1')
	if v:shell_error
		echo l:output
	endif
endfun  " }}}


fun! s:statcmd(path)  " {{{
	silent let l:output = system('stat '.shellescape(a:path, 0))
	echo l:output
endfun  " }}}


fun! s:filecmd(path)  " {{{
	silent let l:output = system('file '.shellescape(a:path, 0))
	echo substitute(l:output, '\n$', '', '')
endfun  " }}}
" }}}


" Buffer configuration {{{
fun! s:lcdundercursor()  " {{{
	let l:path = fnamemodify(s:undercursor(line('.') > 3 ? line('.') : 3), ':h')
	if s:dirreadable(l:path)
		exe 'au filemanager CmdlineEnter <buffer> ++once lcd '.fnameescape(l:path)
	endif
	" For the lack of Enter event after CmdlineLeave since we don't know 
	" whether the user has executed a command. (-1) to display changed 
	" file permissions, if any.
	au! filemanager ShellCmdPost <buffer>
	au filemanager ShellCmdPost <buffer> ++once call s:refreshtree(-1)
endfun  " }}}


fun! s:definemapcmd()  " {{{
	" Separete function because of s:renamemarked()
	command! -buffer -bang -nargs=1  Mark         call s:markbypat(<q-args>, expand('<bang>'))
	command! -buffer -bang -nargs=?  Filter       call s:filter(<q-args>, expand('<bang>'))
	command! -buffer -bang -nargs=?  Bookmark     call s:bookmarkcmd(expand('<bang>'), <q-args>)
	command! -buffer -bang -nargs=?  Delbookmark  call s:bookmarkdel(expand('<bang>'), <q-args>)

	" No need for <silent> with <cmd>
	nnoremap <nowait> <buffer>  ,      zh
	nnoremap <nowait> <buffer>  .      zl
	nnoremap <nowait> <buffer>  <      zH
	nnoremap <nowait> <buffer>  >      zL
	nnoremap <nowait> <buffer>  F      :Filter
	nnoremap <nowait> <buffer>  f      <cmd>call <sid>openbyname()<cr>
	nnoremap <nowait> <buffer>  d      <cmd>call <sid>newdir()<cr>
	nnoremap <nowait> <buffer>  <cr>   <cmd>call <sid>open(<sid>undercursor(), 0)<cr>
	nnoremap <nowait> <buffer>  v      <cmd>call <sid>open(<sid>undercursor(), 1)<cr>
	nnoremap <nowait> <buffer>  o      <cmd>call <sid>open(<sid>undercursor(), 2)<cr>
	nnoremap <nowait> <buffer>  O      <cmd>call <sid>open(<sid>undercursor(), 3)<cr>
	nnoremap <nowait> <buffer>  t      <cmd>call <sid>open(<sid>undercursor(), 4)<cr>
	nnoremap <nowait> <buffer>  s      <cmd>call <sid>open(<sid>undercursor(), 5)<cr>
	nnoremap <nowait> <buffer>  E      <cmd>call <sid>open(<sid>undercursor(), 6)<cr>
	nnoremap <nowait> <buffer>  T      <cmd>call <sid>openterminal(0)<cr>
	nnoremap <nowait> <buffer>  U      <cmd>call <sid>openterminal(1)<cr>
	nnoremap <nowait> <buffer>  l      <cmd>call <sid>descenddir(<sid>undercursor(), 1)<cr>
	nnoremap <nowait> <buffer>  gl     <cmd>call <sid>descenddir(<sid>undercursor(), 0)<cr>
	nnoremap <nowait> <buffer>  h      <cmd>call <sid>parentdir()<cr>
	nnoremap <nowait> <buffer>  zc     <cmd>call <sid>folddir(<sid>undercursor(), 0)<cr>
	nnoremap <nowait> <buffer>  zC     <cmd>call <sid>folddir(<sid>undercursor(), 1)<cr>
	nnoremap <nowait> <buffer>  zo     <cmd>call <sid>toggledir(<sid>undercursor(), 2)<cr>
	nnoremap <nowait> <buffer>  c      <cmd>call <sid>lcdundercursor()<cr>:!
	nnoremap <nowait> <buffer>  x      <cmd>call <sid>openexternal(<sid>undercursor())<cr>
	nnoremap <nowait> <buffer>  S      <cmd>call <sid>statcmd(<sid>undercursor())<cr>
	nnoremap <nowait> <buffer>  gf     <cmd>call <sid>filecmd(<sid>undercursor())<cr>
	nnoremap <nowait> <buffer>  gr     <cmd>call <sid>togglesortreverse()<cr>
	nnoremap <nowait> <buffer>  gm     <cmd>call <sid>setsortmethod()<cr>
	nnoremap <nowait> <buffer>  gS     <cmd>call <sid>setsortorder()<cr>
	nnoremap <nowait> <buffer>  gI     <cmd>call <sid>setignorecase()<cr>
	nnoremap <nowait> <buffer>  gH     <cmd>call <sid>toggleshowhidden()<cr>
	nnoremap <nowait> <buffer>  gG     <cmd>call <sid>togglerespectgitignore()<cr>
	nnoremap <nowait> <buffer>  <c-l>  <cmd>call <sid>refreshtree(0)<cr><c-l>
	nnoremap <nowait> <buffer>  <c-r>  <cmd>call <sid>refreshtree(1)<cr>
	nnoremap <nowait> <buffer>  i      <cmd>call <sid>mark([line('.')])<cr>
	vnoremap <nowait> <buffer>  i      <cmd>call <sid>mark([line('.'), line('v')])<cr>
	nnoremap <nowait> <buffer>  I      <cmd>call <sid>unmarkall()<cr>
	nnoremap <nowait> <buffer>  <esc>  <cmd>call <sid>unmarkall()<cr>
	nnoremap <nowait> <buffer>  C      <cmd>call <sid>cmdonmarked(0)<cr>:!
	vmap     <nowait> <buffer>  C      iC
	nnoremap <nowait> <buffer>  r      <cmd>call <sid>renamemarked()<cr>
	vmap     <nowait> <buffer>  r      ir
	nnoremap <nowait> <buffer>  R      <cmd>call <sid>renametree()<cr>
	nnoremap <nowait> <buffer>  D      <cmd>call <sid>deletemarked()<cr>
	vmap     <nowait> <buffer>  D      iD
	nnoremap <nowait> <buffer>  b      <nop>
	nnoremap <nowait> <buffer>  B      <nop>
	nnoremap <nowait> <buffer>  b<cr>  <cmd>call <sid>printbookmarks()<cr>
	for l:name in s:bookmarknames
		exe 'nnoremap <nowait> <buffer>  B'.l:name.'  <cmd>call <sid>bookmarksave('.string(l:name).', 0)<cr>'
		exe 'nnoremap <nowait> <buffer>  b'.l:name.'  <cmd>call <sid>bookmarkrestore('.string(l:name).')<cr>'
	endfor
endfun  " }}}


fun! s:initialize(path)  " {{{
	" nofile is necessary for independent views of the same directory
	setl bufhidden=wipe buftype=nofile noswapfile
	setl nomodifiable readonly undolevels=-1
	setl nonumber nowrap nofoldenable
	setl conceallevel=3 concealcursor=nc
	let s:timeoutsave = &timeout
	set notimeout

	" Mappings, commands, syntax, autocmds {{{
	call s:definemapcmd()

	syntax clear
	syntax spell notoplevel
	exe 'syntax match fm_regularfile  ".*'.s:separator.'$"        contains=fm_depth,fm_marked,fm_seponly'
	exe 'syntax match fm_directory    ".*'.s:separator.'/$"       contains=fm_depth,fm_marked,fm_ftypeind'
	exe 'syntax match fm_executable   ".*'.s:separator.'\*$"      contains=fm_depth,fm_marked,fm_ftypeind'
	exe 'syntax match fm_symlink      ".*'.s:separator.'@$"       contains=fm_depth,fm_marked,fm_ftypeind'
	exe 'syntax match fm_socket       ".*'.s:separator.'=$"       contains=fm_depth,fm_marked,fm_ftypeind'
	exe 'syntax match fm_fifo         ".*'.s:separator.'|$"       contains=fm_depth,fm_marked,fm_ftypeind'

	exe 'syntax match fm_depth        "^'.s:depthstronlypat.'\+'.s:separator.'" contains=fm_sepdepth contained'
	exe 'syntax match fm_marked       "^'.s:depthstrmarkedpat.'\+'.s:separator.'" contains=fm_sepdepth contained'
	exe 'syntax match fm_sepdepth     "^'.s:depthstrpat.'\+\zs'.s:separator.'" conceal contained'
	exe 'syntax match fm_ftypeind     "'.s:separator.'[\*@=|/]$"  contains=fm_sepftype contained'
	exe 'syntax match fm_sepftype     "'.s:separator.'\ze[\*@=|/]$"  conceal contained'
	exe 'syntax match fm_seponly      "'.s:separator.'$"             conceal contained'

	highlight link fm_regularfile     Normal
	highlight link fm_directory       Directory
	highlight link fm_executable      Question
	highlight link fm_symlink         Identifier
	highlight link fm_socket          PreProc
	highlight link fm_fifo            Statement
	highlight link fm_ftypeind        NonText
	highlight link fm_depth           NonText
	highlight link fm_marked          Search
	highlight link fm_sepdepth        NonText
	highlight link fm_sepftype        NonText
	highlight link fm_seponly         NonText

	syntax match fm_rename_info     '\%^Edit .*$'  contains=fm_rename_button,fm_rename_nontext
	syntax match fm_rename_button   'Enter'        contained
	syntax match fm_rename_button   'Esc'          contained
	syntax match fm_rename_nontext  'NonText'      contained

	hi link fm_rename_info     Statement
	hi link fm_rename_button   PreProc
	hi link fm_rename_nontext  NonText

	" Needed for when the user runs :edit to reload the buffer
	au! filemanager * <buffer>
	au filemanager BufReadCmd    <buffer>  call s:initialize(b:filemanager_treeroot)
	au filemanager BufEnter      <buffer>  call s:refreshtree(0)
	au filemanager BufUnload     <buffer>  call s:exit(str2nr(expand('<abuf>')))
	au filemanager CmdlineEnter  <buffer>  call s:cmdlinechdir(expand('<afile>'))
	au filemanager BufEnter      <buffer>  let s:timeoutsave = &timeout | set notimeout
	au filemanager BufLeave      <buffer>  let &timeout = s:timeoutsave
	" }}}

	let b:filemanager_sortorder = get(t:, 'filemanager_sortorder', s:sortorder)
	let b:filemanager_sortmethod = get(t:, 'filemanager_sortmethod', s:sortmethod)
	let b:filemanager_sortreverse = get(t:, 'filemanager_sortreverse', 0)
	let b:filemanager_ignorecase = get(t:, 'filemanager_ignorecase', s:ignorecase)
	let b:filemanager_respectgitignore = get(t:, 'filemanager_respectgitignore', s:respectgitignore)
	let b:filemanager_showhidden = get(t:, 'filemanager_showhidden', s:showhidden)
	let b:filemanager_orientation = get(t:, 'filemanager_orientation', s:orientation)
	let b:filemanager_filters = []
	let b:filemanager_marked = []

	let b:filemanager_treeroot = substitute(a:path, '[^/]\zs/$', '', '')
	let b:filemanager_tree = s:getdircontents(b:filemanager_treeroot)

	if !exists('b:filemanager_auxiliary')
		let b:filemanager_auxiliary = 0
	endif

	if b:filemanager_auxiliary < 0
		call insert(s:buflist, bufnr(), -b:filemanager_auxiliary - 1)
		let b:filemanager_auxiliary = 0
	else
		call add(s:buflist, bufnr())
	endif

	if s:alwaysfixwinsize && !b:filemanager_auxiliary
		let &winfixwidth = b:filemanager_orientation
		let &winfixheight = !b:filemanager_orientation
	endif

	call s:printtree()
	call cursor(2, 1)
endfun  " }}}


fun! s:getbufnr()  " {{{
	let l:list = filter(copy(s:buflist), 'index(tabpagebuflist(), v:val) != -1')
	return empty(l:list) ? -1 : l:list[0]
endfun  " }}}


fun! s:spawn(dir, bang, orientation)  " {{{
	let l:bufnr = s:getbufnr()
	if a:bang == '!'
		if l:bufnr == -1
			echo 'No filemanager open in current tab'
		else
			if len(getbufinfo({'buflisted': 1})) == 1
				echo 'Already last buffer'
			else
				exe l:bufnr.'bdelete'
			endif
		endif
		return
	endif

	if a:dir == ''
		let l:dir = ''
	elseif && isdirectory(a:dir)
		let l:dir = fnameescape(a:dir)
	else
		echo 'Ignoring "'.a:dir.'": not a directory'
		let l:dir = ''
	endif

	if l:bufnr == -1
		exe 'new '.(l:dir == '' ? '.' : l:dir)
		let l:bufnr = s:buflist[-1]
	elseif l:dir != ''
		echo 'Ignoring command argument'
	endif
	let l:winsave = winnr()
	let l:bufsave = bufnr()
	silent exe bufwinnr(l:bufnr).'wincmd w'
	if a:orientation == 1
		exe 'wincmd '.(s:preferleft ? 'H' : 'L')
		exe 'vertical resize '.(s:winsize * &columns / 100)
		wincmd _
	else
		exe 'wincmd '.(s:preferbelow ? 'J' : 'K')
		exe 'resize '.(s:winsize * &lines / 100)
		if winnr('$') == 1
			wincmd _
		endif
	endif
	let &winfixwidth = a:orientation
	let &winfixheight = !a:orientation
	let b:filemanager_orientation = a:orientation
	if b:filemanager_auxiliary
		let b:filemanager_auxiliary = 0
		if s:dirreadable(b:filemanager_treeroot)
			exe 'tcd '.fnameescape(b:filemanager_treeroot)
		endif
		call s:setbufname()
	endif
	" Makes difference when there are several windows of the same buffer
	silent exe l:winsave.'wincmd w'
	if bufnr() != l:bufsave
		silent exe bufwinnr(l:bufsave).'wincmd w'
	endif
endfun  " }}}


fun! s:enter(path, bufnr)  " {{{
	if !isdirectory(a:path)
		return
	endif
	if !v:vim_did_enter
		return
	endif

	" Don't bother calling anything if already initialized
	if exists('b:filemanager_auxiliary')
		return
	endif

	let l:bufnr = s:getbufnr()
	if l:bufnr == -1
		call s:initialize(simplify(a:path))
	elseif a:bufnr != l:bufnr
		" Allow auxiliary buffers with limited functionality
		let b:filemanager_auxiliary = 1
		call s:initialize(simplify(a:path))
	endif
endfun  " }}}


fun! s:exit(bufnr)  " {{{
	let l:i = index(s:buflist, a:bufnr)
	call remove(s:buflist, l:i)
	if getbufvar(a:bufnr, 'filemanager_auxiliary')
		return
	endif
	" To save the position when BufReadCmd is in action
	call setbufvar(a:bufnr, 'filemanager_auxiliary', -l:i - 1)
	let l:tabnrsave = tabpagenr()
	" Attempt to save config for all relevant tabs, but actually BufUnload 
	" triggers only when the last window (hence in last tab) is closed.
	for l:tabnr in filter(range(1, tabpagenr('$')), 'index(tabpagebuflist(v:val), a:bufnr) != -1')
		exe 'tabnext '.l:tabnr
		let t:filemanager_sortorder = getbufvar(a:bufnr, 'filemanager_sortorder')
		let t:filemanager_sortmethod = getbufvar(a:bufnr, 'filemanager_sortmethod')
		let t:filemanager_sortreverse = getbufvar(a:bufnr, 'filemanager_sortreverse')
		let t:filemanager_ignorecase = getbufvar(a:bufnr, 'filemanager_ignorecase')
		let t:filemanager_respectgitignore = getbufvar(a:bufnr, 'filemanager_respectgitignore')
		let t:filemanager_showhidden = getbufvar(a:bufnr, 'filemanager_showhidden')
		let t:filemanager_orientation = getbufvar(a:bufnr, 'filemanager_orientation')
		if s:bookmarkonbufexit
			call s:bookmarkbackup(a:bufnr)
		endif
	endfor
	exe 'tabnext '.l:tabnrsave
	" The autocmds and variables are unset by vim (bufhidden=wipe)
endfun  " }}}


fun! s:cmdlinechdir(char)  " {{{
	if &autochdir && a:char == ':' && s:dirreadable(b:filemanager_treeroot)
		exe 'lcd '.fnameescape(b:filemanager_treeroot)
	endif
endfun  " }}}
" }}}
