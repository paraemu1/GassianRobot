# Tutorial: Jetson Setup + Remote Access (SSH + Tailscale)

Last updated: 2026-02-06

This tutorial documents the current project setup:
- On-robot compute: NVIDIA Jetson Orin Nano Developer Kit Rev 5.0 (8GB unified memory, L4T R35 / Ubuntu-based)
- Laptop/desktop: used for SSH into the Jetson only
- Remote access: Tailscale installed on the Jetson so you can SSH from anywhere without exposing ports publicly

ROS 2 note: ROS 2 is not an operating system. You run ROS 2 *on Ubuntu* (which the Jetson stays on).

## 0) Prereqs
- You can log into the Jetson locally at least once (monitor/keyboard or initial provisioning method)
- Your laptop has `ssh` available
- You have a Tailscale account you can log into

## 1) Update Jetson OS packages (Ubuntu on L4T R35)
Run on the Jetson:
```bash
sudo apt update
sudo apt upgrade -y
sudo apt autoremove -y
```

## 2) Install + enable OpenSSH (key auth)
Run on the Jetson:
```bash
sudo apt install -y openssh-server
sudo systemctl enable --now ssh
```

From your laptop, generate a keypair (if you don’t already have one):
```bash
ssh-keygen -t ed25519
```

Copy the public key to the Jetson (replace `<jetson_ip_or_hostname>`):
```bash
ssh-copy-id <user>@<jetson_ip_or_hostname>
```

Verify you can log in:
```bash
ssh <user>@<jetson_ip_or_hostname>
```

### Optional hardening (recommended)
After confirming key auth works, consider disabling password auth on the Jetson:
1) Edit `sshd_config`:
```bash
sudo nano /etc/ssh/sshd_config
```
2) Set:
```text
PasswordAuthentication no
```
3) Restart SSH:
```bash
sudo systemctl restart ssh
```

## 3) Install Tailscale (remote-from-anywhere access)
Goal: SSH to the Jetson over your Tailscale network without port forwarding.

On the Jetson, install and bring up Tailscale using the official method for Ubuntu/Debian.
After installing:
```bash
sudo tailscale up
tailscale status
tailscale ip -4
```

On your laptop, ensure you’re logged into the same Tailscale tailnet.

Now SSH using the Jetson’s Tailscale IP:
```bash
ssh <user>@<tailscale_ip>
```

## 4) “This is done” checklist
- You can SSH from laptop → Jetson using keys (no password prompt)
- Tailscale is installed, connected, and stable across reboots
- You can SSH to the Jetson using its Tailscale IP from outside your home network

## 5) Next tutorial to add
Once ROS 2 + sensors are confirmed on the Jetson, add:
- a Jetson-first ROS 2 bringup tutorial (Create 3 connectivity, LiDAR topic, OAK image topic)
- a Jetson-first capture tutorial (record to disk, dataset layout, basic health checks)
