#!/bin/bash

#==========================================
#  Autoconfig ssh security with dialog interface (checkboxes)
#  A.Palamarchuk (mrpalamarchuk93@yandex.ru) 16102024
#==========================================
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin/:/root/bin

# Функция для отображения окна выбора с чекбоксами
choose_options() {
    dialog --checklist "Выберите параметры для применения | Select parameters to apply:" 20 60 11 \
        1 "ClientAliveInterval 300" on \
        2 "PermitRootLogin no" on \
        3 "Protocol 2" on \
        4 "PasswordAuthentication no" on \
        5 "MaxAuthTries 3" on \
        6 "ClientAliveCountMax 0" on \
        7 "X11Forwarding no" on \
        8 "AllowAgentForwarding no" on \
        9 "GSSAPIAuthentication no" on \
        10 "TMOUT=900 (в /etc/profile)" on \
        11 "PermitEmptyPasswords no" on 2>choices.txt
}

# Вызов функции выбора параметров
choose_options

# Чтение выбранных параметров из файла
CHOICES=$(cat choices.txt)

# Удаление временного файла
rm choices.txt

# Проверка, если пользователь не выбрал ничего
if [ -z "$CHOICES" ]; then
    echo "Ничего не выбрано. Выполнение скрипта прервано."
    exit 1
fi

# Начало применения конфигурации
echo "Применяем выбранные параметры..."

SSH_CONFIG_FILE="/etc/ssh/sshd_config"
PROFILE_CONFIG_FILE="/etc/profile"

# Резервное копирование файлов конфигурации
if [ ! -f "${SSH_CONFIG_FILE}.bak" ]; then
    cp $SSH_CONFIG_FILE "${SSH_CONFIG_FILE}.bak"
fi

if [ ! -f "${PROFILE_CONFIG_FILE}.bak" ]; then
    cp $PROFILE_CONFIG_FILE "${PROFILE_CONFIG_FILE}.bak"
fi

# Применение выбранных параметров SSH
for CHOICE in $CHOICES; do
    case $CHOICE in
        1)
            sed -i 's/^#*ClientAliveInterval.*/ClientAliveInterval 300/' $SSH_CONFIG_FILE
            echo "Применён ClientAliveInterval 300"
            ;;
        2)
            sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' $SSH_CONFIG_FILE
            echo "Применён PermitRootLogin no"
            ;;
        3)
            sed -i 's/^#*Protocol.*/Protocol 2/' $SSH_CONFIG_FILE
            echo "Применён Protocol 2"
            ;;
        4)
            sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' $SSH_CONFIG_FILE
            echo "Применён PasswordAuthentication no"
            ;;
        5)
            sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 3/' $SSH_CONFIG_FILE
            echo "Применён MaxAuthTries 3"
            ;;
        6)
            sed -i 's/^#*ClientAliveCountMax.*/ClientAliveCountMax 0/' $SSH_CONFIG_FILE
            echo "Применён ClientAliveCountMax 0"
            ;;
        7)
            sed -i 's/^#*X11Forwarding.*/X11Forwarding no/' $SSH_CONFIG_FILE
            echo "Применён X11Forwarding no"
            ;;
        8)
            sed -i 's/^#*AllowAgentForwarding.*/AllowAgentForwarding no/' $SSH_CONFIG_FILE
            echo "Применён AllowAgentForwarding no"
            ;;
        9)
            sed -i 's/^#*GSSAPIAuthentication.*/GSSAPIAuthentication no/' $SSH_CONFIG_FILE
            echo "Применён GSSAPIAuthentication no"
            ;;
        10)
            if grep -q "^TMOUT=" $PROFILE_CONFIG_FILE; then
                sed -i 's/^TMOUT=.*/TMOUT=900/' $PROFILE_CONFIG_FILE
            else
                echo "TMOUT=900" >> $PROFILE_CONFIG_FILE
            fi
            echo "Применён TMOUT=900 в /etc/profile"
            ;;
        11)
            sed -i 's/^#*PermitEmptyPasswords.*/PermitEmptyPasswords no/' $SSH_CONFIG_FILE
            echo "Применён PermitEmptyPasswords no"
            ;;
    esac
done

# Перезагрузка службы SSH
dialog --yesno "Перезапустить службу SSH для применения изменений? | Restart SSH service to apply changes?" 7 60

if [ $? -eq 0 ]; then
    sudo systemctl restart ssh
    echo "Служба SSH перезапущена."
else
    echo "Перезапуск службы SSH отменён."
fi

echo "Конфигурация завершена."
