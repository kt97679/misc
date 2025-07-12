#!/bin/bash

[ -n "$SSH_TTY" ] && [ "${BASH_SOURCE[0]}" == "${0}" ] && exec bash --rcfile "$SHELL" "$@"

[ -z "$PS1" ] && return

_SHELL=$SHELL
((SHLVL == 1)) && [ -r /etc/profile ] && . /etc/profile
[ -r /etc/skel/.bashrc ] && . <(grep -v "^HIST.*SIZE=" /etc/skel/.bashrc)
SHELL=$_SHELL && unset _SHELL
[ -d "$HOME/bin" ] && [[ ":$PATH:" != *":$HOME/bin:"* ]] && PATH="$HOME/bin:$PATH"

HISTSIZE=$((1024 * 1024))
HISTFILESIZE=$HISTSIZE
HISTTIMEFORMAT='%t%F %T%t'
HISTCONTROL=ignoreboth

update_eternal_history() {
    local histfile_size=$(stat -c %s $HISTFILE 2>/dev/null || echo 0) bash_history=~/.bash_eternal_history old_umask=$(umask)
    history -a
    ((histfile_size == $(stat -c %s $HISTFILE 2>/dev/null || echo 0))) && return
    [ -p ${SHELL}.history ] && bash_history=${SHELL}.history
    umask 077 && echo -e "${USER}\t${HOSTNAME}\t${PWD}\t$(history 1)" >> $bash_history && umask $old_umask
}

[[ "$PROMPT_COMMAND" == *update_eternal_history* ]] || PROMPT_COMMAND="update_eternal_history;$PROMPT_COMMAND"

alias c=cat
alias h='history $((LINES - 1))'
alias l="ls -aFC"
alias ll="ls -aFl"
alias m=less
alias cp="cp -i"
alias mv="mv -i"

bak() { cp $1 $1.$(date +%%F_%T); }
doh() { curl -s -H 'accept: application/dns+json' "https://dns.google.com/resolve?name=$1" | jq; }
sshb() {
    local ssh="ssh -S $(mktemp --dry-run ~/.ssh/control-socket.XXXXXXXX)"
    local hostname=$(ssh -G "$@" | grep -oP "^hostname\s+\K.*")
    local user=$(ssh -G "$@" | grep -oP "^user\s+\K.*")
    local ssh_args=()

    $ssh -fNM "$@" || return $?
    # we collected ssh related command line options in ssh_args, everything after hostname is executed on the remote host
    while :; do ssh_args+=( "$1" ); shift; [ "${ssh_args[-1]}" == "$hostname" ] || [ "${ssh_args[-1]}" == "${user}@${hostname}" ] && break; done

    # check if tail is available
    if [ -n "$($ssh placeholder tail /dev/null || echo oops)" ] || [ -n "$*" ]; then
        # tail not available or remote command is not empty, let's ssh as is
        $ssh "${ssh_args[@]}" "$@"
    else
        # tail is available, no remote command, let's prepare shell
        local bashrc=~/.bashrc
        local bash_history=~/.bash_eternal_history
        local bash_ssh=.$LOGNAME.bash-ssh
        [[ $SHELL =~ .*bash-ssh$ ]] && bash_ssh=$(basename $SHELL) # because we may have nested ssh sessions with different user names
        local bash_ssh_history=${bash_ssh}.history
        [ -r ~/$bash_ssh ] && bashrc=~/$bash_ssh && bash_history=~/$bash_ssh_history
        $ssh placeholder "cat >~/$bash_ssh; [ -p ~/$bash_ssh_history ] || mkfifo -m 0600 ~/$bash_ssh_history" < $bashrc
        ( $ssh -n placeholder "tail -f ~/$bash_ssh_history" | while read -r; do echo "$REPLY" >> $bash_history; done & ) &> /dev/null
        $ssh -t "${ssh_args[@]}" "SHELL=~/$bash_ssh; chmod +x \$SHELL; exec bash --rcfile \$SHELL -i"
    fi
    $ssh placeholder -O exit &> /dev/null
}

type -f rbenv >/dev/null 2>&1 && eval "$(rbenv init -)"
type -f pyenv >/dev/null 2>&1 && eval "$(pyenv init -)"

[ -f ~/.ssh/id_ed25519 ] && [ -f ~/.ssh/id_ed25519.pub ] && {
    export SSH_AUTH_SOCK=~/.ssh/agent
    pgrep -f $SSH_AUTH_SOCK >/dev/null || {
        rm -f $SSH_AUTH_SOCK
        ssh-agent -a $SSH_AUTH_SOCK &>/dev/null
    }
    ssh-add -L | grep -q "$(cut -f1,2 -d' ' ~/.ssh/id_ed25519.pub)" || ssh-add
}

[ -r ~/.byobu/prompt ] && . ~/.byobu/prompt
PS1=$(sed -e 's/..byobu_prompt_runtime..//' <<<"$PS1")

export EDITOR=vim
export DOCKER_HOST=unix:///var/run/docker.sock
