class CompaniesController < ApplicationController
  # GET /companies
  def index
    @companies  = if params[:industry].present?
                    Company.by_industry(params[:industry])
                  else
                    Company.all
                  end
    @industries = Company.industries
  end

  # GET /companies/:id
  def show
    @company      = Company.find(params[:id])
    return render :not_found unless @company

    @employees    = @company.current_employees
    @board        = @company.board_members
    @alumni       = @company.alumni
  end
end
