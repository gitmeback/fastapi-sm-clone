"""add content column to posts table

Revision ID: 134d9a43f339
Revises: fa8d6eac1730
Create Date: 2024-05-10 07:54:08.845514

"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = '134d9a43f339'
down_revision = 'fa8d6eac1730'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('posts', sa.Column('content', sa.String(), nullable=False))
    pass


def downgrade():
    op.drop_column('posts', 'content')
    pass
