#!/bin/bash

[ -n "$SSH_TTY" ] && [ "${BASH_SOURCE[0]}" == "${0}" ] && exec bash --rcfile "$SHELL" "$@"

[ -z "$PS1" ] && return

((SHLVL == 1)) && [ -r /etc/profile ] && . /etc/profile
[ -r /etc/skel/.bashrc ] && . <(grep -v "^HIST.*SIZE=" /etc/skel/.bashrc)
[ -d "$HOME/bin" ] && [[ ":$PATH:" != *":$HOME/bin:"* ]] && PATH="$HOME/bin:$PATH"

[ -z "$SSH_TTY" ] && command -v socat >/dev/null && {
    history_port=26574
    ( : > "/dev/tcp/127.0.0.1/${history_port}" ) &> /dev/null || {
        umask 077 && socat -u TCP4-LISTEN:$history_port,bind=127.0.0.1,reuseaddr,fork OPEN:$HOME/.bash_eternal_history,creat,append &
    }
}

HISTSIZE=$((1024 * 1024))
HISTFILESIZE=$HISTSIZE
HISTTIMEFORMAT='%t%F %T%t'
HISTCONTROL=ignoreboth

update_eternal_history() {
    local histfile_size=$(umask 077 && touch $HISTFILE && stat -c %s $HISTFILE)
    history -a
    ((histfile_size == $(stat -c %s $HISTFILE))) && return
    local history_line="${USER}\t${HOSTNAME}\t${PWD}\t$(history 1)"
    local history_sink=$(readlink ~/.bash-ssh.history 2>/dev/null)
    [ -n "$history_sink" ] && echo -e "$history_line" >"$history_sink" 2>/dev/null && return
    local old_umask=$(umask)
    umask 077
    echo -e "$history_line" >> ~/.bash_eternal_history
    umask $old_umask
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
    local ssh="ssh -S ~/.ssh/control-socket-$(tr -cd '[:alnum:]' < /dev/urandom|head -c8)"
    local bashrc=~/.bashrc
    local history_command="rm -f ~/.bash-ssh.history"
    [ -r ~/.bash-ssh ] && bashrc=~/.bash-ssh && history_port=$(basename $(readlink ~/.bash-ssh.history 2>/dev/null))
    $ssh -fNM "$@" || return $?
    [ -n "$history_port" ] && {
        local history_remote_port="$($ssh -O forward -R 0:127.0.0.1:$history_port placeholder)"
        history_command="ln -nsf /dev/tcp/127.0.0.1/$history_remote_port ~/.bash-ssh.history"
    }
    $ssh placeholder "${history_command}; cat >~/.bash-ssh" < $bashrc
    $ssh "$@" -t 'SHELL=~/.bash-ssh; chmod +x $SHELL; exec bash --rcfile $SHELL -i'
    $ssh placeholder -O exit >/dev/null 2>&1
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
