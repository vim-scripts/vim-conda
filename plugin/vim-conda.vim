" vim-conda
" Version: 0.0.0
" Caleb Hattingh
" MIT Licence

" This is currently hard-coded and is therefore bad. I 
" need some help figure out how to make it user-defined.
set wildcharm=<Tab>


function! s:SetCondaPlainPath()
python << EOF
import os
import subprocess
import json
# This is quite deceiving. `os.environ` loads only a single time,
# when the os module is first loaded. With this embedded-vim
# Python, that means only one time. If we want to have an 
# up-to-date version of the environment, we'll have to use
# Vim's $VAR variables and rather act on that.
# TODO: Fix use of py getenv
path = os.getenv('PATH')
conda_default_env = os.getenv('CONDA_DEFAULT_ENV')
if not conda_default_env:
    pass
else:
    # We appear to be inside a conda env already. We want the path
    # that we would have WITHOUT being in a conda env, e.g. what 
    # we'd get if `deactivate` was run.
    output = subprocess.check_output('conda info --json', shell=True)
    d = json.loads(output)
    # We store the path variable we get if we filter out all the paths
    # that match the current conda "default_prefix".
    # TODO Check whether the generator comprehension also works.
    path = os.pathsep.join([x for x in path.split(os.pathsep) if d['default_prefix'] not in x])
vim.command("let l:temppath = '" + path + "'")
EOF
return l:temppath
endfunction


function! s:CondaActivate(envname, envpath, envsroot)
    " Set environment variables $PATH and $CONDA_DEFAULT_ENV
    let $CONDA_DEFAULT_ENV = a:envname
    let $ANACONDA_ENVS = a:envsroot
    if has("win32") || has("win64")
        let $PATH = a:envpath . ';' . a:envpath . '\Scripts' .';' . g:conda_plain_path
    elseif has("unix")
        let $PATH = a:envpath . '/bin' .  ':' . g:conda_plain_path
    endif
python << EOF
import os
import vim
# It turns out that `os.environ` is loaded only once. Therefore it
# doesn't see the changes we just made above to the vim process env,
# and so we will need to set these
os.environ['CONDA_DEFAULT_ENV'] = vim.eval('a:envname')
os.environ['ANACONDA_ENVS'] = vim.eval('a:envsroot')
os.environ['PATH'] = vim.eval('$PATH')
EOF
endfunction


function! s:CondaDeactivate()
    " Reset $PATH back to what it was at startup, and unset $CONDA_DEFAULT_ENV
    " TODO: Maybe deactivate should really give us `g:conda_plain_path`?
    "       `g:conda_startup_path` would contain env stuff IF vim was started
    "       from inside a conda env..
    let $CONDA_DEFAULT_ENV = g:conda_startup_env
    let $PATH = g:conda_startup_path
python << EOF
import os
import vim
# It turns out that `os.environ` is loaded only once. Therefore it
# doesn't see the changes we just made above to the vim process env,
# and so we will need to update the embedded Python's version of
# `os.environ` manually.
del os.environ['CONDA_DEFAULT_ENV']
del os.environ['ANACONDA_ENVS']
os.environ['PATH'] = vim.eval('$PATH')
EOF
endfunction


function! Conda_env_input_callback(A,L,P)
    " This is the callback for the `input()` function.
    " g:condaenvs will be assigned values inside `s:CondaChangeEnv()` 
    return g:condaenvs
endfunction


""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" This only runs when the script loads
if !exists("g:conda_startup_path")
    let g:conda_startup_path = $PATH
    " If vim is started from inside a conda path, this variable will
    " contain the path WITHOUT the extra conda env bits. Storing this
    " allows us to change conda envs internally inside vim without
    " carrying around any startup baggage in $PATH, if vim was started
    " from a terminal that already had a conda env activated.
    let g:conda_plain_path = s:SetCondaPlainPath()
    " Load all the required Python stuff at startup. These functions 
    " get called from other places.
python << EOF
import vim
import sys
import os
import subprocess
import json
import copy

_conda_py_globals = dict(reset_sys_path=copy.copy(sys.path))  # Mutable global container

def python_input(message = 'input'):
    vim.command('call inputsave()')
    vim.command("let user_input = input('" + message + "', '	', 'custom,Conda_env_input_callback')")
    vim.command('call inputrestore()')
    return vim.eval('user_input')


def obtain_sys_path_from_env(env_path):
    """ Obtain sys.path for the selected python bin folder.
    The given `env_path` should just be the folder, not including
    the python binary. That gets added here.
    
    :param str env_path: The folder containing a Python.
    :return: The sys.path of the provided python env folder.
    :rtype: list """
    pyexe = os.path.join(env_path, 'python')
    args = ' -c "import sys, json; sys.stdout.write(json.dumps(sys.path))"'
    cmd = pyexe + args
    syspath_output = subprocess.check_output(cmd, shell=True)
    # Use json to convert the fetched sys.path cmdline output to a list
    return json.loads(syspath_output)


def conda_activate(env_name, env_path, envs_root):
    """ This function performs a complete (internal) conda env
    activation. There are two primary actions:

    1. Change environment vars $PATH and $CONDA_DEFAULT_ENV

    2. Change EMBEDDED PYTHON sys.path, for jedi-vim code completion 
    
    :return: None """
    # This calls a vim function that will 
    # change the $PATH and $CONDA_DEFAULT_ENV vars
    vim.command("call s:CondaActivate('{}', '{}', '{}')".format(env_name, env_path, envs_root))
    # Obtain sys.path for the selected conda env
    # TODO: Perhaps make this flag a Vim option that users can set?
    ADD_ONLY_SITE_PKGS = True
    if ADD_ONLY_SITE_PKGS:
        new_paths = [os.path.join(env_path, 'lib', 'site-packages')]
    else:
        new_paths = obtain_sys_path_from_env(env_path)
    # Insert the new paths into the EMBEDDED PYTHON sys.path.
    # This is what jedi-vim will use for code completion.
    # TODO: There is another way we could do this: instead of a full reset, we could
    # remember what got added, and the reset process could simply remove those
    # things; this approach would preserve any changes the user makes to 
    # sys.path inbetween calls to s:CondaChangeEnv()... 
    # TODO: I found out that not only does jedi-vim modify sys.path for
    # handling VIRTUALENV (which is what we do here), but it also looks like
    # there is a bug in that the same venv path can get added multiple times.
    # So it looks like the best policy for now is to continue with the
    # current design.
    sys.path = new_paths + _conda_py_globals['reset_sys_path']   # Modify sys.path for Jedi completion
    print 'Activated env: {}'.format(env_name)


def conda_deactivate():
    """ This does the reset. """
    # Resets $PATH and $CONDA_DEFAULT_ENV
    vim.command('call s:CondaDeactivate()')
    # Resets sys.path (embedded Python)
    _conda_py_globals['syspath'] = copy.copy(sys.path)  # Remember the unmodified one
    sys.path = _conda_py_globals['reset_sys_path']   # Modify sys.path for Jedi completion
    print 'Conda env deactivated.'

EOF
endif


" Setting global paths - We use these to switch between conda envs.
if exists("$CONDA_DEFAULT_ENV")
    " This is happening at script startup. It looks like a conda env
    " was already activated before launching vim, so we need to make
    " the required changes internally.
    let g:conda_startup_env = $CONDA_DEFAULT_ENV
python << EOF
conda_deactivate()  # Reset the env paths back to root
# Re-activate. 
conda_default_env = vim.eval('g:conda_startup_env')
conda_activate(
    os.path.basename(conda_default_env), 
    conda_default_env,
    os.path.dirname(conda_default_env))
EOF
else
    let g:conda_startup_env = ""
end


function! s:CondaChangeEnv()
python << EOF

# Obtain conda information. It's great they provide output in 
# json format because it's a short trip to a dict.
output = subprocess.check_output('conda info --json', shell=True)
d = json.loads(output)


# We want to display the env names to the user, not the full paths, but
# we need the full paths for things like $PATH modification and others.
# Thus, we make a dict that maps env name to env path.
# Note the juggling with decode and encode. This is being done to strip
# the annoying `u""` unicode prefixes. There is likely a better way to
# do this. Help would be appreciated.
# keys = [os.path.basename(e).decode().encode('ascii') for e in d['envs']]
keys = [os.path.basename(e).encode('utf-8') for e in d['envs']]
# Create the mapping {envname: envdir}
envnames = dict(zip(keys, d['envs']))
# Add the root as an option (so selecting `root` will trigger a deactivation
envnames['root'] = d['root_prefix']
# Detect the currently-selected env. Remove it from the selectable options.
default_prefix = d['default_prefix']
for key, value in envnames.items():
    if value == default_prefix:
        current_env = key
        # Don't provide current_env as an option for user
        del envnames[key]


# Provide the selectable options to the `input()` callback function via
# a global var: `g:condaenvs`
vim.command('let g:condaenvs = "' + '\n'.join(envnames.keys()) + '"')
# Ask the user to choose a new env
choice = python_input("Change conda env [current: {}]: ".format(current_env))
vim.command('redraw')


if choice == 'root':
    conda_deactivate()
elif choice in envnames:
    conda_activate(choice, envnames[choice], os.path.dirname(envnames[choice]))
elif len(choice) > 0:
    vim.command('echo "Selected env `{}` not found."'.format(choice))
else:
    # Do nothing, i.e. no change or message
    pass
vim.command('redraw')
EOF
endfunction

command! CondaChangeEnv call s:CondaChangeEnv()

" ISSUES
" http://stackoverflow.com/questions/13402899/why-does-my-vim-command-line-path-differ-from-my-shell-path
" THERE ARE OTHER ISSUES..SHELLS MUST MATCH
" https://github.com/gmarik/Vundle.vim/issues/510
" https://github.com/davidhalter/jedi-vim/issues/280
" https://github.com/davidhalter/jedi/issues/385
" https://github.com/davidhalter/jedi-vim/issues/196
" 
"
