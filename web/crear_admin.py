"""Crea (o cambia) la cuenta de administrador de LaLigaDB.

Uso:  doble clic en crear-admin.bat   o   .venv\\Scripts\\python crear_admin.py
Pide el usuario y la contraseña por teclado. La contraseña no se guarda en ningún
fichero: en la base de datos solo queda su hash (scrypt). Hay una sola cuenta; si
ya existe, se sustituye.
"""
import getpass
import sys

from werkzeug.security import generate_password_hash

from db import ErrorDatos, ejecutar_como_dbo


def main():
    print("\n  Cuenta de administrador de LaLigaDB\n")
    nombre = input("  Usuario [admin]: ").strip() or "admin"
    if len(nombre) < 3:
        sys.exit("  El usuario debe tener al menos 3 caracteres.")
    clave = getpass.getpass("  Contraseña (mínimo 10 caracteres; no se ve al escribir): ")
    if len(clave) < 10:
        sys.exit("  La contraseña es demasiado corta.")
    if getpass.getpass("  Repite la contraseña: ") != clave:
        sys.exit("  Las contraseñas no coinciden.")
    try:
        ejecutar_como_dbo("EXEC web.usp_GuardarAdmin @Nombre = ?, @HashClave = ?",
                          (nombre, generate_password_hash(clave, method="scrypt")))
    except ErrorDatos as error:
        sys.exit(f"  No se ha podido guardar: {error}\n  ¿Has ejecutado database\\08_web.sql?")
    print(f"\n  Listo. Ya puedes entrar en la web como «{nombre}».\n")


if __name__ == "__main__":
    main()
