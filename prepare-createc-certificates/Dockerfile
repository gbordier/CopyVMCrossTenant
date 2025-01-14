
FROM mcr.microsoft.com/powershell:latest

COPY . .

RUN apt-get update && apt -y install openssh-server && apt clean

EXPOSE 22
RUN [ "/usr/bin/pwsh","-command","\"install-module az.accounts -force\""]
RUN mkdir /run/sshd

CMD ["/usr/sbin/sshd", "-D"]
