#!/bin/sh
#==========================================
#  Autoconfig ssh security
#==========================================
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin/:/root/bin

echo "==============================================="
echo "\033[0;31m" #red
echo "RU: ВНИМАНИЕ! Данный скрипт изменит ваш sshd_config, будет создана резервная копия с названием sshd_config.bak."
echo "EN: ATTENTION! This script will change your sshd_config, a backup copy will be created with the name sshd_config.bak."
echo "\033[0m" #white
echo "==============================================="

# Запрос подтверждения
read -p "Вы уверены, что хотите продолжить? | Are you sure you want to continue? (y/n): " answer

# Проверка ответа пользователя
if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
  echo "Получен ответ 'Нет'"
  echo "Выполнение скрипта прервано."
  echo ""
  echo "The answer is 'No'"
  echo "Script execution has been interrupted."
  exit 1
else
  echo "\033[0;32m" #green
  echo "Продолжаем выполнение скрипта..."
  echo "We continue to execute the script..."
  echo "\033[0m" #white
  
  # Конфигурация для /etc/ssh/sshd_configex
  SSH_CONFIG_FILE="/etc/ssh/sshd_config"
  
  # Резервное копирование оригинального файла
  if [ ! -f "${SSH_CONFIG_FILE}.bak" ]; then
      cp $SSH_CONFIG_FILE "${SSH_CONFIG_FILE}.bak"
  fi
  
  # Обновление конфигурации SSH
  sed -i 's/^#*ClientAliveInterval.*/ClientAliveInterval 300/' $SSH_CONFIG_FILE
  sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' $SSH_CONFIG_FILE
  sed -i 's/^#*Protocol.*/Protocol 2/' $SSH_CONFIG_FILE
  sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' $SSH_CONFIG_FILE
  sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 3/' $SSH_CONFIG_FILE
  sed -i 's/^#*ClientAliveCountMax.*/ClientAliveCountMax 0/' $SSH_CONFIG_FILE
  sed -i 's/^#*X11Forwarding.*/X11Forwarding no/' $SSH_CONFIG_FILE
  sed -i 's/^#*AllowAgentForwarding.*/AllowAgentForwarding no/' $SSH_CONFIG_FILE
  sed -i 's/^#*GSSAPIAuthentication.*/GSSAPIAuthentication no/' $SSH_CONFIG_FILE
  
  # Конфигурация для /etc/profile
  PROFILE_CONFIG_FILE="/etc/profile"
  
  # Резервное копирование оригинального файла
  if [ ! -f "${PROFILE_CONFIG_FILE}.bak" ]; then
      cp $PROFILE_CONFIG_FILE "${PROFILE_CONFIG_FILE}.bak"
  fi
  
  # Установка TMOUT в 900 секунд (15 минут)
  if grep -q "^TMOUT=" $PROFILE_CONFIG_FILE; then
      sed -i 's/^TMOUT=.*/TMOUT=900/' $PROFILE_CONFIG_FILE
  else
      echo "TMOUT=900" >> $PROFILE_CONFIG_FILE
  fi

  echo "==============================================="
  echo "\033[0;31m" #red
  echo "Перезапустить службу SSH для применения изменений? | Restart SSH service to apply changes?"
  echo "RU: Внимание! Это может вызвать проблему со следующим подключением по SSH т.к. будет доступен вход только по сертификатам!"
  echo "EN: Attention! This may cause a problem with the next SSH connection because only certificates will be available!"
  echo "\033[0m" #white
  echo "==============================================="
  
  # Запрос на перезапуск SSH
  read -p "Перезапустить SSH? | Restart SSH? (y/n): " restart_ssh
  if [ "$restart_ssh" != "y" ] && [ "$restart_ssh" != "Y" ]; then
    echo "RU: Перезапуск SSH отменен. Изменения вступят в силу после ручного перезапуска."
    echo "EN: SSH restart cancelled. Changes will take effect after manual restart."
    exit 1
  else
    echo "\033[0;32m" #green
    echo "RU: Перезапуск службы SSH..."
    echo "EN: Restarting SSH service..."
    echo "\033[0m" #white
    # Здесь команда для перезапуска SSH, например:
    sudo systemctl restart ssh
  fi
  
  echo "\033[0;32m" #green
  echo "RU: Конфигурация завершена. Пожалуйста, перезайдите в систему для применения изменений."
  echo "EN: The configuration is complete. Please log back in to apply the changes."
  echo "\033[0m" #white
fi
