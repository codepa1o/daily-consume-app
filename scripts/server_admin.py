"""SSH deployment helper. Credentials come only from environment variables."""
import argparse
import os
from pathlib import Path

import paramiko


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--command')
    parser.add_argument('--command-file')
    parser.add_argument('--upload', nargs=2, metavar=('LOCAL', 'REMOTE'))
    parser.add_argument('--download', nargs=2, metavar=('REMOTE', 'LOCAL'))
    args = parser.parse_args()
    known_hosts = Path.home() / '.ssh' / 'daily-consume-known-hosts'
    known_hosts.parent.mkdir(parents=True, exist_ok=True)
    client = paramiko.SSHClient()
    if known_hosts.exists():
        client.load_host_keys(str(known_hosts))
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        client.connect(os.environ.get('DAILY_SSH_HOST', '47.99.142.117'),
                       username=os.environ.get('DAILY_SSH_USER', 'root'),
                       password=os.environ['DAILY_SSH_PASSWORD'],
                       timeout=15, auth_timeout=15, look_for_keys=False, allow_agent=False)
        client.save_host_keys(str(known_hosts))
        if args.upload:
            with client.open_sftp() as sftp:
                sftp.put(*args.upload)
        if args.download:
            Path(args.download[1]).parent.mkdir(parents=True, exist_ok=True)
            with client.open_sftp() as sftp:
                sftp.get(*args.download)
        command = (Path(args.command_file).read_text(encoding='utf-8')
                   if args.command_file else args.command)
        if command:
            _, stdout, stderr = client.exec_command(command, timeout=300)
            print(stdout.read().decode('utf-8', errors='replace'), end='')
            print(stderr.read().decode('utf-8', errors='replace'), end='')
            raise SystemExit(stdout.channel.recv_exit_status())
    finally:
        client.close()


if __name__ == '__main__':
    main()
