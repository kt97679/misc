[ -z "$PS1" ] && return

[ -f /etc/skel/.bashrc ] && . <(grep -v "^HIST.*SIZE=" /etc/skel/.bashrc)

HISTSIZE=$((1024 * 1024))
HISTFILESIZE=$HISTSIZE
HISTTIMEFORMAT='%t%F %T%t'
[[ "$PROMPT_COMMAND" == *bash_eternal_history* ]] || export PROMPT_COMMAND+="${PROMPT_COMMAND:+ ;} history -a ; "'echo -e $USER\\t$HOSTNAME\\t$PWD\\t"$(history 1)" >> ~/.bash_eternal_history'
touch ~/.bash_eternal_history && chmod 0600 ~/.bash_eternal_history

alias c=cat
alias h='history $((LINES - 1))'
alias l="ls -aFC"
alias ll="ls -aFl"
alias m=less
alias cp="cp -i"
alias mv="mv -i"

bak() { cp $1 $1.$(date +%s); }

#umask 0002
export EDITOR=vim

[ -d "$HOME/bin" ] && [[ ":$PATH:" != *":$HOME/bin:"* ]] && PATH="$HOME/bin:$PATH"

type -f rbenv >/dev/null 2>&1 && eval "$(rbenv init -)"
type -f pyenv >/dev/null 2>&1 && eval "$(pyenv init -)"

export SSH_AUTH_SOCK=$(find /tmp/ssh-*/agent.* -user $LOGNAME 2>/dev/null | head -n1)
[ -z "$SSH_AUTH_SOCK" ] && . <(ssh-agent)
ssh-add -L | grep -q "$(cut -f1,2 -d' ' ~/.ssh/id_rsa.pub)" || ssh-add

[ -r ~/.byobu/prompt ] && . ~/.byobu/prompt   #byobu-prompt#
